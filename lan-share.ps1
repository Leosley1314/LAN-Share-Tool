<#
============================================================
 局域网共享工具  (LAN Share Setup)
 -----------------------------------------------------------
 兼容性 : Windows Vista / 7 / 8 / 10 / 11 (PowerShell 2.0+)
 界面    : 图形界面(GUI)
 语言    : 简体中文
 版本    : v1.3
 ============================================================
#>

param(
    [string]$SharePath = '',
    [string]$ShareUser = '',
    [string]$SharePw = '',
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
$script:EnablePasswordlessGuest = $true
$script:EnableNetDiscovery      = $true
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

# DPI 感知
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

$effGuest     = [bool]($script:EnablePasswordlessGuest -and (-not $NoGuest))

Add-Type -AssemblyName System.Drawing
function Get-Accent {
    $c = [System.Drawing.Color]::FromArgb(0, 120, 212)
    try {
        $ac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        $ar = [uint32]$ac
        $c = [System.Drawing.Color]::FromArgb([int]($ar -band 0xFF), [int](($ar -shr 8) -band 0xFF), [int](($ar -shr 16) -band 0xFF))
    } catch {}
    return $c
}
function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value ('[' + $ts + '] ' + $Msg) -Encoding UTF8 -ErrorAction SilentlyContinue
}
$effDiscovery = [bool]($script:EnableNetDiscovery -and (-not $NoDiscovery))


# ---------- 前置检查 ----------
function Pre-Check {
    Write-Log '=== 前置检查 ==='
    $os = Get-WmiObject Win32_OperatingSystem
    $ver = [Version]$os.Version
    Write-Log ("系统: " + $os.Caption + " (Build " + $ver.Build + ")")
    if ($ver.Major -lt 6) { Write-Log '警告: Windows XP 不支持' }
    try {
        $smb1 = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name SMB1 -ErrorAction SilentlyContinue).SMB1
        Write-Log ("SMB1: " + $(if ($smb1 -eq 1) {'已启用'} else {'未启用'}))
    } catch {}
    $svc = Get-Service LanmanServer -ErrorAction SilentlyContinue
    if ($svc) { Write-Log ("LanmanServer: " + $svc.Status + "/" + $svc.StartType) }
    Write-Log '=== 检查完毕 ==='
}

# ---------- 进度窗口 ----------
$script:progressForm = $null
$script:progressLabel = $null
$script:progressBar = $null
function Show-Progress {
    Add-Type -AssemblyName System.Windows.Forms
    $script:progressForm = New-Object System.Windows.Forms.Form
    $script:progressForm.Text = '正在配置...'
    $script:progressForm.ClientSize = New-Object System.Drawing.Size(420, 110)
    $script:progressForm.StartPosition = 'CenterScreen'
    $script:progressForm.FormBorderStyle = 'FixedDialog'
    $script:progressForm.MaximizeBox = $false
    $script:progressForm.MinimizeBox = $false
    $script:progressLabel = New-Object System.Windows.Forms.Label
    $script:progressLabel.Location = New-Object System.Drawing.Point(15, 15)
    $script:progressLabel.Size = New-Object System.Drawing.Size(390, 22)
    $script:progressLabel.Text = '准备中...'
    $script:progressForm.Controls.Add($script:progressLabel)
    $script:progressBar = New-Object System.Windows.Forms.ProgressBar
    $script:progressBar.Location = New-Object System.Drawing.Point(15, 45)
    $script:progressBar.Size = New-Object System.Drawing.Size(390, 20)
    $script:progressBar.Minimum = 0
    $script:progressBar.Maximum = 100
    $script:progressForm.Controls.Add($script:progressBar)
    $script:progressForm.Show()
    $script:progressForm.Refresh()
}
function Update-Progress {
    param([string]$Text, [int]$Percent)
    if ($script:progressForm) {
        $script:progressLabel.Text = $Text
        $script:progressBar.Value = $Percent
        $script:progressForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}
function Close-Progress {
    if ($script:progressForm) { $script:progressForm.Close(); $script:progressForm = $null }
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class WinHide {[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int n);}' -ErrorAction Stop } catch {}
    try { $cw = [WinHide]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][WinHide]::ShowWindowAsync($cw, 0) } } catch {}

    $form = New-Object System.Windows.Forms.Form
    $sysFont = [System.Drawing.SystemFonts]::DefaultFont
    $accent = Get-Accent
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

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = '选择要共享的磁盘或文件夹，点下方按钮即可。'
    $lblSub.Font = New-Object System.Drawing.Font($sysFont.FontFamily, 11)
    $lblSub.Location = New-Object System.Drawing.Point(10, 30)
    $lblSub.Size = New-Object System.Drawing.Size(600, 24)
    $lblSub.TextAlign = 'MiddleCenter'
    $form.Controls.Add($lblSub)

    $gbPath = New-Object System.Windows.Forms.GroupBox
    $gbPath.Text = ' 共享位置 '
    $gbPath.Location = New-Object System.Drawing.Point(25, 85)
    $gbPath.Size = New-Object System.Drawing.Size(570, 110)
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
        $g.DrawString($s.Items[$e.Index].ToString(), $s.Font, $br, 8, $e.Bounds.Top + 3)
    })
    $drivePaths = New-Object System.Collections.ArrayList
    $drives = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 -and $_.FileSystem -eq 'NTFS' } | Sort-Object DeviceID
    foreach ($d in $drives) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        [void]$drivePaths.Add($d.DeviceID + '\')
        $vol = $d.VolumeName; if (-not $vol) { $vol = '本地磁盘' }
        [void]$combo.Items.Add(($d.DeviceID + ' ' + $vol + ' (' + $sizeGB + ' GB)'))
    }
    [void]$combo.Items.Add('自定义')
    $combo.SelectedIndex = 0
    $gbPath.Controls.Add($combo)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(18, 78)
    $txt.Size = New-Object System.Drawing.Size(354, 24)
    $txt.Visible = $false
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(380, 76)
    $btnBrowse.Size = New-Object System.Drawing.Size(84, 28)
    $btnBrowse.Visible = $false
    $gbPath.Controls.Add($txt)
    $gbPath.Controls.Add($btnBrowse)

    $gbOpt = New-Object System.Windows.Forms.GroupBox
    $gbOpt.Text = ' 选项 '
    $gbOpt.Location = New-Object System.Drawing.Point(25, 205)
    $gbOpt.Size = New-Object System.Drawing.Size(570, 185)
    $form.Controls.Add($gbOpt)

    $chkGuest = New-Object System.Windows.Forms.CheckBox
    $chkGuest.Text = '开启无密码访客访问'
    $chkGuest.Location = New-Object System.Drawing.Point(18, 28)
    $chkGuest.Size = New-Object System.Drawing.Size(540, 24)
    $chkGuest.Checked = $true
    $gbOpt.Controls.Add($chkGuest)

    $chkDisc = New-Object System.Windows.Forms.CheckBox
    $chkDisc.Text = '启用网络发现'
    $chkDisc.Location = New-Object System.Drawing.Point(18, 56)
    $chkDisc.Size = New-Object System.Drawing.Size(540, 24)
    $chkDisc.Checked = $true
    $gbOpt.Controls.Add($chkDisc)

    $chkRO = New-Object System.Windows.Forms.CheckBox
    $chkRO.Text = '只读共享'
    $chkRO.Location = New-Object System.Drawing.Point(18, 84)
    $chkRO.Size = New-Object System.Drawing.Size(540, 24)
    $chkRO.Checked = $false
    $gbOpt.Controls.Add($chkRO)

    $chkPrinter = New-Object System.Windows.Forms.CheckBox
    $chkPrinter.Text = '启用打印机共享'
    $chkPrinter.Location = New-Object System.Drawing.Point(18, 112)
    $chkPrinter.Size = New-Object System.Drawing.Size(540, 24)
    $chkPrinter.Checked = $true
    $gbOpt.Controls.Add($chkPrinter)

    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 5000
    $tip.InitialDelay = 500
    $tip.ReshowDelay = 200
    $tip.SetToolTip($chkGuest, ("勾选后同一网络内任何设备无需密码即可访问共享。" + [Environment]::NewLine + "不勾选则需输入用户名密码访问。"))
    $tip.SetToolTip($chkDisc, ('让其他设备在网络文件夹中看到这台电脑。' + [Environment]::NewLine + '不勾选则需通过 \\电脑名 或 IP 地址直接访问。'))
    $tip.SetToolTip($chkRO, "其他设备只能打开和复制文件，不能修改、删除或写入。")
    $tip.SetToolTip($chkPrinter, "局域网内其他电脑可使用这台电脑连接的打印机。")

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
        $lblUser.Visible = $show; $txtUser.Visible = $show
        $lblPw.Visible = $show; $txtPw.Visible = $show
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

    $btnView = New-Object System.Windows.Forms.Button
    $btnView.Text = '查看共享'
    $btnView.Size = New-Object System.Drawing.Size(150, 36)
    $btnView.Location = New-Object System.Drawing.Point(40, 465)
    $btnView.FlatStyle = 'Flat'
    $btnView.FlatAppearance.BorderColor = $accent
    $btnView.FlatAppearance.BorderSize = 1
    $btnView.BackColor = [System.Drawing.Color]::White
    $btnView.ForeColor = $accent
    $form.Controls.Add($btnView)
    $btnView.add_Click({
        $vw = New-Object System.Windows.Forms.Form
        $vw.Text = '当前共享状态'
        $vw.ClientSize = New-Object System.Drawing.Size(520, 380)
        $vw.StartPosition = 'CenterParent'
        $vw.FormBorderStyle = 'FixedDialog'
        $vw.MaximizeBox = $false
        $vw.MinimizeBox = $false
        $vw.BackColor = [System.Drawing.Color]::White
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(15, 15)
        $lv.Size = New-Object System.Drawing.Size(490, 320)
        $lv.View = 'Details'
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.Columns.Add('共享名', 130) | Out-Null
        $lv.Columns.Add('路径', 280) | Out-Null
        $lv.Columns.Add('类型', 70) | Out-Null
        try {
            $shares = Get-WmiObject Win32_Share | Where-Object { $_.Name -notmatch "^(ADMIN|IPC)" }
            foreach ($s in $shares) {
                $typeStr = switch ($s.Type) { 0 {'磁盘'} 1 {'打印'} default {'其他'} }
                [void]$lv.Items.Add((New-Object System.Windows.Forms.ListViewItem(@($s.Name, $s.Path, $typeStr))))
            }
        } catch {}
        if ($lv.Items.Count -eq 0) {
            [void]$lv.Items.Add((New-Object System.Windows.Forms.ListViewItem(@("(无共享)", "", ""))))
        }
        $vw.Controls.Add($lv)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = '关闭'
        $btnClose.Size = New-Object System.Drawing.Size(100, 30)
        $btnClose.Location = New-Object System.Drawing.Point(210, 345)
        $btnClose.FlatStyle = 'Flat'
        $btnClose.FlatAppearance.BorderSize = 0
        $btnClose.BackColor = $accent
        $btnClose.ForeColor = [System.Drawing.Color]::White
        $vw.Controls.Add($btnClose)
        $btnClose.add_Click({ $vw.Close() })
        [void]$vw.ShowDialog()
    })

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = '取消所有共享'
    $btnClear.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $btnClear.FlatStyle = 'Flat'
    $btnClear.Location = New-Object System.Drawing.Point(430, 515)
    $btnClear.Size = New-Object System.Drawing.Size(150, 36)
    $btnClear.BackColor = [System.Drawing.Color]::White
    $btnClear.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $form.Controls.Add($btnClear)
    $btnClear.add_Click({
        $c = [System.Windows.Forms.MessageBox]::Show('将删除所有共享并移除防火墙规则，还原为默认状态。继续吗？', '确认', 'YesNo', 'Question')
        if ($c -ne 'Yes') { return }
        if ($script:IsExe) {
            Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-ClearAll','-NoPause')
        } else {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-ClearAll','-NoPause')
        }
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
    })

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
        $txt.Text = "局域网共享工具 v1.3" + $nl + $nl +
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
        $ok.Size = New-Object System.Drawing.Size(85, 30)
        $ok.FlatStyle = "Flat"
        $ok.FlatAppearance.BorderSize = 0
        $ok.BackColor = $accent
        $ok.ForeColor = [System.Drawing.Color]::White
        $about.Controls.Add($ok)
        $ok.add_Click({ $about.Close() })
        [void]$about.ShowDialog()
    })

    $btnRestart = New-Object System.Windows.Forms.Button
    $btnRestart.Text = '重启资源管理器'
    $btnRestart.Size = New-Object System.Drawing.Size(150, 36)
    $btnRestart.Location = New-Object System.Drawing.Point(40, 515)
    $btnRestart.FlatStyle = 'Flat'
    $btnRestart.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $btnRestart.FlatAppearance.BorderSize = 1
    $btnRestart.BackColor = [System.Drawing.Color]::White
    $btnRestart.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $form.Controls.Add($btnRestart)
    $btnRestart.add_Click({
        $c = [System.Windows.Forms.MessageBox]::Show("将重启 Windows 资源管理器（桌面会短暂消失后自动恢复）。继续吗？", "确认", "YesNo", "Question")
        if ($c -ne "Yes") { return }
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Start-Process explorer.exe
    })

    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = '开始配置'
    $btnStart.BackColor = $accent
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = 'Flat'
    $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.Size = New-Object System.Drawing.Size(150, 36)
    $btnStart.Location = New-Object System.Drawing.Point(235, 515)
    $form.Controls.Add($btnStart)


    $btnStart.add_MouseEnter({ $btnStart.BackColor = $accentDark })
    $btnStart.add_MouseLeave({ $btnStart.BackColor = $accent })
    $btnStart.add_Click({
        $btnStart.Enabled = $false
        $selPath = ''
        $idx = $combo.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $drivePaths.Count) { $selPath = $drivePaths[$idx] }
        elseif ($idx -eq $drivePaths.Count) {
            $selPath = $txt.Text.Trim()
            if (-not $selPath) {
                [void][System.Windows.Forms.MessageBox]::Show('请先输入要共享的文件夹路径。', '提示')
                $btnStart.Enabled = $true; return
            }
        } else { $selPath = $script:DefaultSharePath }

        $launchArgs = @('-NoPause')
        if ($selPath) { $launchArgs += @('-SharePath', $selPath) }
        if ($chkRO.Checked) { $launchArgs += '-ReadOnly' }
        if (-not $chkGuest.Checked) { $launchArgs += '-NoGuest'; if ($txtUser.Text.Trim()) { $launchArgs += @('-ShareUser', $txtUser.Text.Trim()) }; if ($txtPw.Text) { $launchArgs += @('-SharePw', $txtPw.Text) } }
        if (-not $chkDisc.Checked) { $launchArgs += '-NoDiscovery' }
        if (-not $chkPrinter.Checked) { $launchArgs += '-NoPrinter' }

        if ($script:IsExe) {
            Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $launchArgs
        } else {
            $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath) + $launchArgs
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs
        }
        $btnStart.Enabled = $true
    })

    [void]$form.ShowDialog()
}

function Show-Disclaimer {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.Form
    $accent = Get-Accent

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

if (-not $ClearAll -and -not $SharePath -and -not $ShareAll) { $Gui = $true }
if ($Gui) {
    if (-not (Show-Disclaimer)) { exit }
    Show-Gui
    exit
}

# ---------- 自我提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    $innerArgs = @()
    if ($SharePath)   { $innerArgs += @('-SharePath', $SharePath) }
    if ($ReadOnly)    { $innerArgs += '-ReadOnly' }
    if ($NoGuest)     { $innerArgs += '-NoGuest' }
    if ($ShareUser)   { $innerArgs += @('-ShareUser', $ShareUser) }
    if ($SharePw)     { $innerArgs += @('-SharePw', $SharePw) }
    if ($NoDiscovery) { $innerArgs += '-NoDiscovery' }
    if ($NoPause)     { $innerArgs += '-NoPause' }
    if ($ClearAll)    { $innerArgs += '-ClearAll' }
    if ($ShareAll)    { $innerArgs += '-ShareAll' }
    if ($NoPrinter)   { $innerArgs += '-NoPrinter' }
    if ($script:IsExe) {
        Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $innerArgs
    } else {
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:scriptPath) + $innerArgs
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs
    }
    exit
}

if ($ClearAll) {
    Show-Progress
    Update-Progress '取消所有共享...' 50
    $shares = @()
    try { $shares = Get-WmiObject Win32_Share | Where-Object { $_.Name -notmatch '^(ADMIN|IPC|print$)' } } catch {}
    foreach ($s in $shares) {
        try {
            $ret = $s.Delete()
            if ($ret.ReturnValue -ne 0) { $null = & net.exe share $s.Name /delete 2>&1 }
        } catch {}
    }
    foreach ($rn in 'LAN-SMB-In-TCP','LAN-NB-In-TCP','LAN-NB-In-UDP') {
        $null = netsh advfirewall firewall delete rule name=$rn 2>&1
    }
    Update-Progress '关闭 SMB1 协议...' 70
    try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name SMB1 -Value 0 -Type DWord -Force } catch {}
    Update-Progress '关闭 Server 服务...' 85
    try { Stop-Service LanmanServer -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service LanmanServer -StartupType Manual -ErrorAction SilentlyContinue } catch {}
    Update-Progress '完成' 100
    Start-Sleep 1
    Close-Progress
    [void][System.Windows.Forms.MessageBox]::Show('已取消所有共享。', '完成', 'OK', 'Information')
    exit
}

# ---------- 开始配置 ----------
Show-Progress
Update-Progress '前置检查...' 5
Pre-Check
Update-Progress '网络设为专用...' 15
try {
    $profiles = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -ErrorAction Stop
    foreach ($pr in $profiles) { Set-ItemProperty -Path $pr.PSPath -Name 'Category' -Value 1 -Type DWord -ErrorAction SilentlyContinue }
} catch {}

Update-Progress '配置防火墙...' 30
foreach ($g in @('文件和打印机共享','File and Printer Sharing')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes profile=any }
if ($effDiscovery) { foreach ($g in @('网络发现','Network Discovery')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes profile=any } }
foreach ($r in @(@{n='LAN-SMB-In-TCP';p='TCP';port='445'},@{n='LAN-NB-In-TCP';p='TCP';port='137-139'},@{n='LAN-NB-In-UDP';p='UDP';port='137-139'})) {
    $null = netsh advfirewall firewall add rule name=$($r.n) dir=in action=allow protocol=$($r.p) localport=$($r.port) profile=any
}

Update-Progress '启动系统服务...' 50
$svcList = @('FDResPub','FDpHost','upnphost','SSDPSRV')
if (-not $NoPrinter) { $svcList += 'spooler' }
foreach ($svc in $svcList) { $null = sc.exe config $svc start= auto; $null = sc.exe start $svc 2>&1 }
$null = sc.exe config LanmanWorkstation start= auto
$null = sc.exe start LanmanWorkstation 2>&1
$null = sc.exe config LanmanServer start= auto
$null = sc.exe start LanmanServer 2>&1
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'SMB1' -Value 1 -Type DWord -ErrorAction Stop
} catch {}
    # Windows 8+ 启用 SMB1 功能（如未安装则安装）
    try {
        $osVer = (Get-WmiObject Win32_OperatingSystem).Version
        if ([Version]$osVer -ge [Version]'6.2') {
            $null = dism.exe /online /enable-feature /featurename:SMB1Protocol /all /norestart 2>&1
        }
    } catch {}

Update-Progress '配置 Guest 访问...' 70
if ($effGuest) {
    $null = net.exe user Guest /active:yes 2>&1
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'RestrictNullSessAccess' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'everyoneincludesanonymous' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    $null = net.exe user Guest /passwordchg:no 2>&1
}

Update-Progress '创建共享...' 85
$sharePath = $script:InSharePath
if (-not $sharePath) { $sharePath = 'D:\' }
if (-not (Test-Path $sharePath)) {
    $sharePath = (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:'} | Select-Object -First 1).DeviceID + '\'
}
$shareName = if ($sharePath -match '^[A-Za-z]:\\$') { $sharePath.Substring(0,1) } else { Split-Path $sharePath -Leaf }
# 确定共享授权账户
$grantUser = "Everyone"
if ($effGuest) {
    $grantUser = "Guest"
} elseif ($ShareUser) {
    $grantUser = $ShareUser
    if ($SharePw) { $null = net.exe user $ShareUser $SharePw 2>&1 }
    $null = net.exe user Guest /active:no 2>&1
}
$sharePerm = if ($ReadOnly) { 'READ' } else { 'FULL' }
$ntfsPerm  = if ($ReadOnly) { 'R' } else { 'M' }
if ($ShareAll) {
    foreach ($d in (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:' -and $_.FileSystem -eq 'NTFS'})) {
        $p = $d.DeviceID + '\'; $n = $d.DeviceID.Substring(0,1)
        $null = & net.exe share "$n=$p" "/grant:${grantUser},${sharePerm}" 2>&1
        $null = & icacls $p /grant "${grantUser}:(OI)(CI)${ntfsPerm}" 2>&1
    }
} else {
    $null = & net.exe share "$shareName=$sharePath" "/grant:${grantUser},${sharePerm}" 2>&1
    $null = & icacls $sharePath /grant "${grantUser}:(OI)(CI)${ntfsPerm}" 2>&1
}

Update-Progress '获取访问地址...' 95
$ip = $null
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
foreach ($a in $adapters) {
    foreach ($addr in $a.IPAddress) {
        if ($addr -match '^\d+\.\d+\.\d+\.\d+$' -and $addr -notlike '127.*' -and $addr -notlike '169.254.*') { $ip = $addr; break }
    }
    if ($ip) { break }
}
Update-Progress '完成' 100
Start-Sleep 1
Close-Progress

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
[void][System.Windows.Forms.MessageBox]::Show($msg, "配置完成", "OK", "Information")
