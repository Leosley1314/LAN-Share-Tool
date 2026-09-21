<#
============================================================
 局域网共享工具  (LAN Share Setup)
 -----------------------------------------------------------
 兼容性 : Windows Vista / 7 / 8 / 10 / 11 (PowerShell 2.0+)
  界面    : 图形界面(GUI)
  语言    : 简体中文
 -----------------------------------------------------------
 功能：
  1. 网络配置文件设为"专用"
  2. 启用防火墙"文件和打印机共享"、"网络发现"规则(含端口兜底)
  3. 启动网络发现相关系统服务
  4. 开启无密码访客(Guest)访问(移除"拒绝从网络访问"策略)
  5. 交互选择要共享的磁盘或文件夹，并创建/更新共享
  6. 自动验证并输出访问方式
============================================================
#>

param(
    [string]$SharePath = '',
    [string]$ShareName = '',
    [string]$ShareUser = '',
    [switch]$ReadOnly,
    [switch]$NoGuest,
    [switch]$NoDiscovery,
    [switch]$NoPause,
    [switch]$NoElevate,
    [switch]$Gui,
    [switch]$ClearAll,
    [switch]$NoPrinter,
    [switch]$ShareAll
)
$script:InSharePath = $SharePath

# =============== 配置区（按需修改） ===============
$script:DefaultSharePath        = 'D:\'
$script:DefaultShareName       = ''
$script:EnablePasswordlessGuest = $true
$script:EnableNetDiscovery     = $true
$script:ReadOnlyDefault         = $false
# =================================================

$ErrorActionPreference = 'Continue'
$script:scriptPath = $MyInvocation.MyCommand.Path
if (-not $script:scriptPath) {
    try { $script:scriptPath = [Environment]::GetCommandLineArgs()[0] } catch {}
}
if (-not $script:scriptPath) {
    try { $script:scriptPath = (Get-Process -Id $PID).Path } catch {}
}
if (-not $script:scriptPath) { $script:scriptPath = (Join-Path (Get-Location).Path 'lan-share.ps1') }
$scriptDir = Split-Path -Parent $script:scriptPath
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$script:IsExe = ($script:scriptPath -match '(?i)\.exe$')
$logFile = Join-Path $scriptDir '局域网配置日志(重启后删除).txt'
$logLines = New-Object System.Collections.ArrayList

# DPI 感知 - 解决高分屏模糊
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAwareness {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@ -ErrorAction Stop
    [void][DpiAwareness]::SetProcessDPIAware()
} catch {}
$effReadOnly  = [bool]($script:ReadOnlyDefault -or $ReadOnly)
$effGuest     = [bool]($script:EnablePasswordlessGuest -and (-not $NoGuest))
$effDiscovery = [bool]($script:EnableNetDiscovery -and (-not $NoDiscovery))

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    [void]$logLines.Add("[$ts] $Msg")
    Write-Host $Msg -ForegroundColor Cyan
    # 实时追加到日志文件，便于中途排查
    try { Add-Content -Path $logFile -Value ("[$ts] $Msg") -Encoding UTF8 } catch {}
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class DpiAwareness {[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();}' -ErrorAction Stop; [void][DpiAwareness]::SetProcessDPIAware() } catch {}
    try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class WinHide {[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int n);}' -ErrorAction Stop } catch {}
    try { $cw = [WinHide]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][WinHide]::ShowWindowAsync($cw, 0) } } catch {}
    try { $mw = (Get-Process -Id $PID).MainWindowHandle; if ($mw -ne [IntPtr]::Zero) { [void][WinHide]::ShowWindowAsync($mw, 0) } } catch {}

    $form = New-Object System.Windows.Forms.Form
    $sysFont = [System.Drawing.SystemFonts]::DefaultFont
    # 读取 Windows 系统强调色（Win10/11），读不到用默认蓝
    $accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    try {
        $ac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        $ar = [uint32]$ac
        $r = [int]($ar -band 0xFF)
        $g = [int](($ar -shr 8) -band 0xFF)
        $b = [int](($ar -shr 16) -band 0xFF)
        $accent = [System.Drawing.Color]::FromArgb($r, $g, $b)
    } catch {}
    $accentDark = [System.Drawing.Color]::FromArgb([int]($accent.R*0.82), [int]($accent.G*0.82), [int]($accent.B*0.82))

    $form.Font = $sysFont
    try {
        $icoPath = Join-Path $scriptDir 'lan-share.ico'
        if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
    } catch {}
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Text = '局域网共享工具'
    $form.ShowInTaskbar = $true
    $form.ClientSize = New-Object System.Drawing.Size(620, 580)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White

    # 标题
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = '选择要共享的磁盘或文件夹，点下方按钮即可。'
    $lblSub.Font = New-Object System.Drawing.Font($sysFont.FontFamily, 11)
    $lblSub.Location = New-Object System.Drawing.Point(10, 30)
    $lblSub.Location = New-Object System.Drawing.Point(10, 30)
    $lblSub.Size = New-Object System.Drawing.Size(600, 20)
    $form.Controls.Add($lblSub)
    # 分组：共享位置
    $gbPath = New-Object System.Windows.Forms.GroupBox
    $gbPath.Text = ' 共享位置 '
    $gbPath.Location = New-Object System.Drawing.Point(25, 85)
    $gbPath.Size = New-Object System.Drawing.Size(570, 110)
    $gbPath.Anchor = 'Top, Left, Right'
    $form.Controls.Add($gbPath)

    $lblPick = New-Object System.Windows.Forms.Label
    $lblPick.Text = '选择要共享的内容（磁盘=整盘，自定义=文件夹）：'
    $lblPick.Location = New-Object System.Drawing.Point(12, 25)
    $lblPick.Size = New-Object System.Drawing.Size(540, 20)
    $gbPath.Controls.Add($lblPick)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location = New-Object System.Drawing.Point(12, 50)
    $combo.Size = New-Object System.Drawing.Size(546, 24)
    $combo.Anchor = 'Top, Left, Right'
    $combo.DrawMode = 'OwnerDrawFixed'
    $combo.ItemHeight = 22
    $combo.add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $bSelected = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
        if ($bSelected) {
            $g.FillRectangle((New-Object System.Drawing.SolidBrush($accent)), $e.Bounds)
            $br = [System.Drawing.Brushes]::White
        } else {
            $g.FillRectangle([System.Drawing.Brushes]::White, $e.Bounds)
            $br = [System.Drawing.Brushes]::Black
        }
        $txt = $s.Items[$e.Index].ToString()
        $g.DrawString($txt, $s.Font, $br, 8, $e.Bounds.Top + 3)
    })
    $drivePaths = New-Object System.Collections.ArrayList
    $drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 -and $_.FileSystem -eq 'NTFS' } | Sort-Object DeviceID
    foreach ($d in $drives) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
        [void]$drivePaths.Add($d.DeviceID + '\')
        $vol = $d.VolumeName; if (-not $vol) { $vol = '本地磁盘' }
        [void]$combo.Items.Add(($d.DeviceID + ' ' + $vol + ' (' + $sizeGB + ' GB)'))
    }
    [void]$combo.Items.Add('自定义')
    $combo.SelectedIndex = 0
    $gbPath.Controls.Add($combo)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(18, 78)
        $txt.Size = New-Object System.Drawing.Size(480, 340)
    $txt.Visible = $false
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(380, 76)
    $btnBrowse.Size = New-Object System.Drawing.Size(84, 28)
    $btnBrowse.Visible = $false

    # 分组：选项
    $gbOpt = New-Object System.Windows.Forms.GroupBox
    $gbOpt.Text = ' 选项 '
    $gbOpt.Location = New-Object System.Drawing.Point(25, 205)
    $gbOpt.Size = New-Object System.Drawing.Size(570, 185)
    $gbOpt.Anchor = 'Top, Left, Right'
    $form.Controls.Add($gbOpt)

    $chkGuest = New-Object System.Windows.Forms.CheckBox
    $chkGuest.Text = '开启无密码访客访问（客人身份免密登录）'
    $chkGuest.Location = New-Object System.Drawing.Point(18, 28)
    $chkGuest.Size = New-Object System.Drawing.Size(540, 24)
    $chkGuest.Checked = $true
    $gbOpt.Controls.Add($chkGuest)

    $chkDisc = New-Object System.Windows.Forms.CheckBox
    $chkDisc.Text = '启用网络发现（让其他设备能"看到"这台电脑）'
    $chkDisc.Location = New-Object System.Drawing.Point(18, 56)
    $chkDisc.Size = New-Object System.Drawing.Size(540, 24)
    $chkDisc.Checked = $true
    $gbOpt.Controls.Add($chkDisc)

    $chkRO = New-Object System.Windows.Forms.CheckBox
    $chkRO.Text = '只读共享（其他设备只能读取，不能修改）'
    $chkRO.Location = New-Object System.Drawing.Point(18, 84)
    $chkRO.Size = New-Object System.Drawing.Size(540, 24)
    $chkRO.Checked = $false
    $gbOpt.Controls.Add($chkRO)
    # 打印机共享开关
    $chkPrinter = New-Object System.Windows.Forms.CheckBox
    $chkPrinter.Text = '启用打印机共享'
    $chkPrinter.Location = New-Object System.Drawing.Point(18, 112)
    $chkPrinter.Size = New-Object System.Drawing.Size(540, 24)
    $chkPrinter.Checked = $true
    $gbOpt.Controls.Add($chkPrinter)

    # 账号密码（仅取消无密码访客时显示）
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = '用户名:'
    $lblUser.Location = New-Object System.Drawing.Point(18, 144)
    $lblUser.Size = New-Object System.Drawing.Size(62, 22)
    $lblUser.Visible = $false
    $gbOpt.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(82, 142)
    $txtUser.Size = New-Object System.Drawing.Size(120, 22)
    $txtUser.Text = $env:USERNAME
    $txtUser.Visible = $false
    $gbOpt.Controls.Add($txtUser)
    $lblPw = New-Object System.Windows.Forms.Label
    $lblPw.Text = '密码:'
    $lblPw.Location = New-Object System.Drawing.Point(215, 144)
    $lblPw.Size = New-Object System.Drawing.Size(50, 22)
    $lblPw.Visible = $false
    $gbOpt.Controls.Add($lblPw)
    $txtPw = New-Object System.Windows.Forms.TextBox
    $txtPw.Location = New-Object System.Drawing.Point(270, 142)
    $txtPw.Size = New-Object System.Drawing.Size(180, 22)
    $txtPw.PasswordChar = '*'
    $txtPw.Visible = $false
    $gbOpt.Controls.Add($txtPw)

    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Text = '点"开始配置"后请求管理员权限，自动完成全部设置。'
    $lblTip.ForeColor = [System.Drawing.Color]::Gray
    $lblTip.Location = New-Object System.Drawing.Point(25, 410)
    $lblTip.Size = New-Object System.Drawing.Size(570, 34)
    $lblTip.TextAlign = 'MiddleCenter'
    $form.Controls.Add($lblTip)

    $chkGuest.add_CheckedChanged({
        $show = -not $chkGuest.Checked
        $lblUser.Visible = $show
        $txtUser.Visible = $show
        $lblPw.Visible = $show
        $txtPw.Visible = $show
    })

    $combo.add_SelectedIndexChanged({
        $idx = $combo.SelectedIndex
        if ($idx -eq $drivePaths.Count) { $txt.Visible = $true; $btnBrowse.Visible = $true }
        else { $txt.Visible = $false; $btnBrowse.Visible = $false }
    })

    $btnBrowse.add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择要共享的文件夹'
        if ($dlg.ShowDialog() -eq 'OK') { $txt.Text = $dlg.SelectedPath }
    })

    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = '开始配置'
    $btnStart.BackColor = $accent
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = 'Flat'
    $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.Size = New-Object System.Drawing.Size(150, 36)
    $form.Controls.Add($btnStart)
    $btnStart.Location = New-Object System.Drawing.Point(235, 515)
    $btnStart.add_MouseEnter({ $btnStart.BackColor = $accentDark })
    $btnStart.add_MouseLeave({ $btnStart.BackColor = $accent })
    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.FlatStyle = 'Flat'
    $btnAbout.Text = '关于'
    $btnAbout.Size = New-Object System.Drawing.Size(150, 36)
    $btnAbout.FlatAppearance.BorderColor = $accent
    $btnAbout.FlatAppearance.BorderSize = 1
    $btnAbout.Location = New-Object System.Drawing.Point(430, 465)
    $btnAbout.BackColor = [System.Drawing.Color]::White
    $btnAbout.ForeColor = $accent
    $form.Controls.Add($btnAbout)
    $btnAbout.add_Click({
        $nl = [Environment]::NewLine
        $about = New-Object System.Windows.Forms.Form
        $about.Text = "关于"
        $about.ClientSize = New-Object System.Drawing.Size(520, 420)
        $about.StartPosition = "CenterParent"
        $about.FormBorderStyle = "FixedDialog"
        $about.MaximizeBox = $false
        $about.MinimizeBox = $false
        $about.BackColor = [System.Drawing.Color]::White
        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(20, 15)
        $txt.Size = New-Object System.Drawing.Size(480, 340)
        $txt.Text = "局域网共享工具 v1.1" + $nl + $nl +
            "在家庭/办公局域网内快速配置文件共享与打印机共享。" + $nl +
            "兼容 Windows Vista 及以上系统，需管理员权限。" + $nl + $nl +
            "免责声明：" + $nl +
            "1. 无密码访客(Guest)模式下，同一网络内任何设备均可读写共享内容，请勿在公共网络环境开启。" + $nl +
            "2. 共享整个磁盘会暴露该盘全部文件，可能被误删、篡改或泄露，请先确认无敏感数据。" + $nl +
            "3. 请仅在你信任并可控的网络中使用；配置完成后建议及时关闭不再需要的共享。" + $nl +
            "4. 本工具按原样提供，不附带任何担保；因使用导致的数据损失由使用者自行承担。"
        $about.Controls.Add($txt)
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = "GitHub"
        $link.Location = New-Object System.Drawing.Point(20, 372)
        $link.Size = New-Object System.Drawing.Size(350, 20)
        $link.add_LinkClicked({ Start-Process "https://github.com/Leosley1314/lan-share-tool" })
        $about.Controls.Add($link)
        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = "确定"
        $ok.Location = New-Object System.Drawing.Point(420, 368)
        $ok.Size = New-Object System.Drawing.Size(75, 28)
        $ok.FlatStyle = "Flat"
        $ok.FlatAppearance.BorderSize = 0
        $ok.BackColor = $accent
        $ok.ForeColor = [System.Drawing.Color]::White
        $about.Controls.Add($ok)
        $ok.add_Click({ $about.Close() })
        [void]$about.ShowDialog()
    })


    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '共享所有磁盘'
    $btnAll.Location = New-Object System.Drawing.Point(235, 465)
    $btnAll.Size = New-Object System.Drawing.Size(150, 36)
    $btnAll.FlatStyle = 'Flat'
    $btnAll.FlatAppearance.BorderColor = $accent
    $btnAll.FlatAppearance.BorderSize = 1
    $btnAll.BackColor = [System.Drawing.Color]::White
    $btnAll.ForeColor = $accent
    $form.Controls.Add($btnAll)
    $btnAll.add_Click({
        $c = [System.Windows.Forms.MessageBox]::Show("将共享所有非 C 盘的磁盘（D、E 等）。继续吗？", "确认", "YesNo", "Question")
        if ($c -ne "Yes") { return }
        $launchArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$script:scriptPath,"-ShareAll","-NoPause")
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $launchArgs
        [void][System.Windows.Forms.MessageBox]::Show("正在共享所有磁盘，请耐心等待...","提示","OK","Information")
    })
    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = '取消所有共享'
    $btnClear.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $btnClear.FlatStyle = 'Flat'
    $btnClear.Location = New-Object System.Drawing.Point(40, 465)
    $btnClear.Size = New-Object System.Drawing.Size(150, 36)
    $btnClear.BackColor = [System.Drawing.Color]::White
    $btnClear.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $form.Controls.Add($btnClear)
    $btnClear.add_Click({
        $c = [System.Windows.Forms.MessageBox]::Show('将删除所有共享并移除防火墙规则，还原为默认状态。继续吗？', '确认', 'YesNo', 'Question')
        if ($c -ne 'Yes') { return }

        if ($script:IsExe) {
            Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-ClearAll')
        } else {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-ClearAll','-NoPause')
        }
    })
    $btnStart.add_Click({
        $btnStart.Enabled = $false
        $selPath = ''
        $idx = $combo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $drivePaths.Count) { $selPath = $drivePaths[$idx] }
        elseif ($idx -eq $drivePaths.Count) {
            $selPath = $txt.Text.Trim()
            if (-not $selPath) {
                [void][System.Windows.Forms.MessageBox]::Show('请先输入要共享的文件夹路径。', '提示')
                $btnStart.Enabled = $true
                return
            }
        }
        else { $selPath = $script:DefaultSharePath }

        if ($script:IsExe) {
            $launchArgs = @('-NoPause')
            if ($selPath) { $launchArgs += @('-SharePath', $selPath) }
            if ($chkRO.Checked) { $launchArgs += '-ReadOnly' }
            if (-not $chkGuest.Checked) { $launchArgs += '-NoGuest'; if ($txtUser.Text.Trim()) { $launchArgs += @('-ShareUser', $txtUser.Text.Trim()) } }
            if (-not $chkDisc.Checked) { $launchArgs += '-NoDiscovery' }
            if (-not $chkPrinter.Checked) { $launchArgs += '-NoPrinter' }

            Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $launchArgs
        } else {
            $launchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-NoPause')
            if ($selPath) { $launchArgs += @('-SharePath', $selPath) }
            if ($chkRO.Checked) { $launchArgs += '-ReadOnly' }
            if (-not $chkGuest.Checked) { $launchArgs += '-NoGuest'; if ($txtUser.Text.Trim()) { $launchArgs += @('-ShareUser', $txtUser.Text.Trim()) } }
            if (-not $chkDisc.Checked) { $launchArgs += '-NoDiscovery' }
            if (-not $chkPrinter.Checked) { $launchArgs += '-NoPrinter' }

            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $launchArgs
        }
    })

    [void]$form.ShowDialog()
}

# ============================================================
# 入口
# ============================================================

function Show-Disclaimer {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.Form
    $accent = [System.Drawing.Color]::FromArgb(0, 120, 212)
    try {
        $ac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        $ar = [uint32]$ac
        $r = [int]($ar -band 0xFF)
        $g = [int](($ar -shr 8) -band 0xFF)
        $b = [int](($ar -shr 16) -band 0xFF)
        $accent = [System.Drawing.Color]::FromArgb($r, $g, $b)
    } catch {}
    $dlg.Text = "免责声明"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 300)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $txt = New-Object System.Windows.Forms.Label
    $txt.Location = New-Object System.Drawing.Point(20, 15)
    $txt.Size = New-Object System.Drawing.Size(440, 220)
    $nl = [Environment]::NewLine
    $txt.Text = "使用前请阅读免责声明：" + $nl + $nl +
        "1. 无密码访客(Guest)模式下，同一网络内任何设备均可读写共享内容，请勿在公共网络环境开启。" + $nl +
        "2. 共享整个磁盘会暴露该盘全部文件，可能被误删、篡改或泄露，请先确认无敏感数据。" + $nl +
        "3. 请仅在你信任并可控的网络中使用；配置完成后建议及时关闭不再需要的共享。" + $nl +
        "4. 本工具按原样提供，不附带任何担保；因使用导致的数据损失由使用者自行承担。"
    $dlg.Controls.Add($txt)
    $btnAccept = New-Object System.Windows.Forms.Button
    $btnAccept.Text = "接受"
    $btnAccept.Location = New-Object System.Drawing.Point(250, 245)
    $btnAccept.Size = New-Object System.Drawing.Size(90, 30)
    $btnAccept.FlatStyle = "Flat"
    $btnAccept.FlatAppearance.BorderSize = 0
    $btnAccept.BackColor = $accent
    $btnAccept.ForeColor = [System.Drawing.Color]::White
    $btnAccept.add_Click({ $dlg.DialogResult = "OK"; $dlg.Close() })
    $dlg.Controls.Add($btnAccept)
    $btnReject = New-Object System.Windows.Forms.Button
    $btnReject.Text = "拒绝"
    $btnReject.Location = New-Object System.Drawing.Point(360, 245)
    $btnReject.Size = New-Object System.Drawing.Size(90, 30)
    $btnReject.FlatStyle = "Flat"
    $btnReject.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200,60,60)
    $btnReject.FlatAppearance.BorderSize = 1
    $btnReject.BackColor = [System.Drawing.Color]::White
    $btnReject.ForeColor = [System.Drawing.Color]::FromArgb(200,60,60)
    $btnReject.add_Click({ $dlg.DialogResult = "Cancel"; $dlg.Close() })
    $dlg.Controls.Add($btnReject)
    return $dlg.ShowDialog() -eq "OK"
}

if (-not $ClearAll -and -not $SharePath -and -not $ShareAll) { $Gui = $true }  # 双击无参数时开 GUI
if ($Gui) {
    if (-not (Show-Disclaimer)) { exit }
    Show-Gui
    exit
}
# ---------- 自我提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    # 用数组传参，PowerShell 自动给含空格的参数加引号，避免提权时参数被吞
    if ($script:IsExe) {
        $innerArgs = @()
        if ($SharePath)   { $innerArgs += @('-SharePath', $SharePath) }
        if ($ShareName)   { $innerArgs += @('-ShareName', $ShareName) }
        if ($ReadOnly)    { $innerArgs += '-ReadOnly' }
        if ($NoGuest)     { $innerArgs += '-NoGuest' }
        if ($ShareUser)   { $innerArgs += @('-ShareUser', $ShareUser) }
        if ($NoDiscovery) { $innerArgs += '-NoDiscovery' }
        if ($NoPause)     { $innerArgs += '-NoPause' }
        Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
        if ($ClearAll)     { $innerArgs += '-ClearAll' }
        Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $innerArgs
    } else {
        $innerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:scriptPath)
        if ($SharePath)   { $innerArgs += @('-SharePath', $SharePath) }
        if ($ShareName)   { $innerArgs += @('-ShareName', $ShareName) }
        if ($ReadOnly)    { $innerArgs += '-ReadOnly' }
        if ($NoGuest)     { $innerArgs += '-NoGuest' }
        if ($ShareUser)   { $innerArgs += @('-ShareUser', $ShareUser) }
        if ($NoDiscovery) { $innerArgs += '-NoDiscovery' }
        if ($NoPause)     { $innerArgs += '-NoPause' }
        Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
        if ($ClearAll)     { $innerArgs += '-ClearAll' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $innerArgs
    }
    exit
}



if ($ClearAll) {
    Write-Host '======== 取消所有共享（还原默认状态） ========' -ForegroundColor Yellow
    $shares = @()
    try { $shares = Get-WmiObject Win32_Share | Where-Object { $_.Name -notmatch '^(ADMIN|IPC|print$)' } } catch { Write-Host ('查询失败: ' + $_.Exception.Message) -ForegroundColor Red }
    Write-Host ('找到 ' + @($shares).Count + ' 个共享')
    foreach ($s in $shares) {
        try {
            $ret = $s.Delete()
            if ($ret.ReturnValue -eq 0) { Write-Host ('已删除: ' + $s.Name) -ForegroundColor Green }
            else {
                $null = & net.exe share $s.Name /delete 2>&1
                Write-Host ('net删除: ' + $s.Name + '  WMI代码=' + $ret.ReturnValue) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ('异常: ' + $s.Name + ' - ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    foreach ($rn in 'LAN-SMB-In-TCP','LAN-NetBIOS-In-TCP','LAN-NetBIOS-In-UDP','LAN-SSDP-In-UDP','LAN-WSD-In-UDP','LAN-WSD-In-TCP','LAN-WSD-In-TCP2') {
        $null = netsh advfirewall firewall delete rule name=$rn 2>&1
    }
    Write-Host '已移除本工具添加的防火墙规则。'
    if (-not $NoPause) { Read-Host '按回车键退出...' }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show('已取消所有共享，还原为默认状态。', '完成', 'OK', 'Information')
    } catch {}
    exit
}
Write-Log '================ 局域网共享配置开始 ================'

Write-Host ''
Write-Host '本程序将执行以下操作：' -ForegroundColor Yellow
Write-Host '  1. 把当前网络设为"专用"'
Write-Host '  2. 放行防火墙文件共享/网络发现规则'
Write-Host '  3. 开启无密码访客(Guest)访问'
Write-Host '  4. 创建共享并授权 Everyone'
Write-Host ''
if ($NoPause) { $confirm = 'y' } else { $confirm = Read-Host '确认开始配置吗? (y/n)' }
if ($confirm -notmatch '^[yY]') { exit }

# 1. 网络设为专用
try {
    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -ErrorAction Stop
    foreach ($pr in $profiles) {
        Set-ItemProperty -Path $pr.PSPath -Name 'Category' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    }
    Write-Log '网络: 已设为专用'
} catch { Write-Log '网络配置跳过' }

# 2. 防火墙
foreach ($g in @('文件和打印机共享','File and Printer Sharing')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes }
if ($effDiscovery) { foreach ($g in @('网络发现','Network Discovery')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes } }
foreach ($r in @(@{n='LAN-SMB-In-TCP';p='TCP';port='445'},@{n='LAN-NB-In-TCP';p='TCP';port='137-139'},@{n='LAN-NB-In-UDP';p='UDP';port='137-139'})) {
    $null = netsh advfirewall firewall add rule name=$($r.n) dir=in action=allow protocol=$($r.p) localport=$($r.port) profile=private
}
Write-Log '防火墙规则已启用'

# 3. 服务
$svcList = @('FDResPub','upnphost','SSDPSRV')
if (-not $NoPrinter) { $svcList += 'spooler' }
foreach ($svc in $svcList) { $null = sc.exe config $svc start= auto; $null = sc.exe start $svc 2>&1 }

# 4. Guest
if ($effGuest) {
    $null = net.exe user Guest /active:yes 2>&1
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'RestrictNullSessAccess' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Write-Log 'Guest 访问已启用'
}

# 5. 共享
$sharePath = $script:InSharePath
if (-not $sharePath) { $sharePath = 'D:\' }
if (-not (Test-Path $sharePath)) { $sharePath = (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:'} | Select-Object -First 1).DeviceID + '\' }
$shareName = if ($sharePath -match '^[A-Za-z]:\\$') { $sharePath.Substring(0,1) } else { Split-Path $sharePath -Leaf }
if ($ShareAll) {
    foreach ($d in (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:' -and $_.FileSystem -eq 'NTFS'})) {
        $p = $d.DeviceID + '\'; $n = $d.DeviceID.Substring(0,1)
        $null = & net.exe share "$n=$p" "/grant:Everyone,FULL" 2>&1
    }
} else {
    $null = & net.exe share "$shareName=$sharePath" "/grant:Everyone,FULL" 2>&1
    $null = & icacls $sharePath /grant 'Everyone:(OI)(CI)M' 2>&1
}

# 6. 获取IP
$ip = $null
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
foreach ($a in $adapters) {
    foreach ($addr in $a.IPAddress) {
        if ($addr -match '^\d+\.\d+\.\d+\.\d+$' -and $addr -notlike '127.*' -and $addr -notlike '169.254.*') { $ip = $addr; break }
    }
    if ($ip) { break }
}
if ($NoPause) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        if ($ShareAll) {
            $msg = "磁盘共享设置完毕！" + "`n`n"
            if ($ip) { $msg += "Windows 访问: \\" + $ip + "`n" }
            if ($ip) { $msg += "手机访问: smb://" + $ip + "`n" }
        } else {
            $msg = "局域网共享配置完成！" + "`n`n"
            $msg += "共享路径: " + $sharePath + "`n"
            $msg += "共享名称: " + $shareName + "`n"
            if ($ip) { $msg += "Windows 访问: \\" + $ip + "\" + $shareName + "`n" }
            if ($ip) { $msg += "手机访问: smb://" + $ip + "`n" }
        }
        $msg += "`n详细日志: " + $logFile
        [void][System.Windows.Forms.MessageBox]::Show($msg, "配置完成", "OK", "Information")
    } catch {}
} else {
    Read-Host "按回车键退出..."
}
