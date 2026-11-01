#Requires -Version 5.0
# ============================================================================
#  PCL 一键恢复工具 v1.1
#  恢复 PCL2 到 2.14.0.0 旧版本，找回 MC 下载功能
#
#  更新策略（v1.1）：
#    · 正常更新【放行】—— PCL 自动更新照常用
#    · 坏更新【自动撤回】—— 只有"砍掉 MC 下载"的版本（≥ 2.99）会被
#      更新守卫自动撤回到备份版本
#    · 可选：开机自动守卫（登录时静默检查一次）
#    · 可选：完全锁定更新（旧版行为，禁止一切更新，最保险）
#
#  背景：2026年10月20日，国内多款 MC 第三方启动器因举报事件
#        被迫关停 MC 本体下载功能。本工具帮助用户回退到
#        仍可正常下载的旧版本。
#
#  用法：
#    双击 PCL恢复工具.bat          打开图形界面
#    powershell -File 本脚本.ps1 -Guard   静默守卫（开机自启用，无需手动）
#
#  Author: 鲸鱼娘 & YG
#  License: MIT
# ============================================================================

param(
    [switch]$Guard
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================================
#  配置
# ============================================================================
$script:AppVersion    = "1.1.0"
$script:OldPCLVersion = "2.14.0.0"
$script:ExeName       = "Plain Craft Launcher 2.exe"

# 坏更新判定：此版本起砍掉了 MC 下载功能（被撤回的就是它）
$script:BadVersionMin = [version]"2.99.0.0"

# 下载源（按顺序尝试）
$script:DownloadUrls = @(
    "https://github.com/Meloong-Git/PCL/archive/refs/tags/2.14.0.0.zip",
    "https://mirror.ghproxy.com/https://github.com/Meloong-Git/PCL/archive/refs/tags/2.14.0.0.zip",
    "https://ghfast.top/https://github.com/Meloong-Git/PCL/archive/refs/tags/2.14.0.0.zip"
)

# 临时目录 / 配置文件（配置按机器存，不进压缩包）
$script:TempBase   = Join-Path $env:TEMP "PCLRecovery_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss'))"
$script:ConfigDir  = Join-Path $env:APPDATA "PCLGuard"
$script:ConfigFile = Join-Path $script:ConfigDir "config.json"
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "PCL更新守卫.lnk"

function Get-ToolConfig {
    try { if (Test-Path $script:ConfigFile) { return (Get-Content $script:ConfigFile -Raw | ConvertFrom-Json) } } catch { }
    return [pscustomobject]@{ PclDir = ""; AutoGuard = $false; LockAll = $false }
}
function Save-ToolConfig {
    param([string]$PclDir, [bool]$AutoGuard, [bool]$LockAll)
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    @{ PclDir = $PclDir; AutoGuard = $AutoGuard; LockAll = $LockAll } |
        ConvertTo-Json | Set-Content -Path $script:ConfigFile -Encoding UTF8
}

# ============================================================================
#  日志与状态（无 GUI 时自动退化为写日志文件）
# ============================================================================
$script:GuardLog = Join-Path $script:ConfigDir "guard.log"
function Write-Log {
    param([string]$Message, [string]$Color = "Gainsboro")
    $timestamp = Get-Date -Format "HH:mm:ss"
    if ($null -ne $logBox) {
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.SelectionColor = [System.Drawing.Color]::FromName($Color)
        $logBox.AppendText("[$timestamp] $Message`r`n")
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        try { Add-Content -Path $script:GuardLog -Value "[$timestamp] $Message" -Encoding UTF8 } catch { }
    }
}
function Set-Status {
    param([string]$Text, [int]$Progress = -1)
    if ($null -ne $statusLabel) { $statusLabel.Text = $Text }
    if ($Progress -ge 0 -and $null -ne $progressBar) {
        $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $Progress))
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# ============================================================================
#  PCL 自动检测
# ============================================================================
function Find-PCLInstallations {
    $found = [System.Collections.Generic.List[string]]::new()

    # 1) 常见安装路径
    $commonPaths = @(
        "D:\pcl2", "D:\PCL", "C:\PCL", "E:\PCL", "F:\PCL",
        "D:\Plain Craft Launcher 2", "C:\Plain Craft Launcher 2",
        "$env:USERPROFILE\Desktop\PCL",
        "D:\Games\PCL", "C:\Games\PCL",
        "D:\Minecraft\PCL", "C:\Minecraft\PCL"
    )
    foreach ($p in $commonPaths) {
        $driveRoot = $p.Substring(0, [Math]::Min(3, $p.Length))
        if (-not (Test-Path $driveRoot -ErrorAction SilentlyContinue)) { continue }
        try {
            if (Test-Path (Join-Path $p $script:ExeName) -ErrorAction Stop) {
                $found.Add($p)
            }
        } catch { }
    }

    # 2) 桌面快捷方式
    $desktopDirs = @(
        [Environment]::GetFolderPath("Desktop"),
        [Environment]::GetFolderPath("CommonDesktopDirectory")
    )
    foreach ($dir in $desktopDirs) {
        if (-not (Test-Path $dir)) { continue }
        try {
            $shell = New-Object -ComObject WScript.Shell
            foreach ($lnk in Get-ChildItem $dir -Filter "*.lnk" -ErrorAction SilentlyContinue) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    if ($sc.TargetPath -match "Plain Craft Launcher") {
                        $targetDir = Split-Path $sc.TargetPath -Parent
                        if ((Test-Path (Join-Path $targetDir $script:ExeName)) -and (-not $found.Contains($targetDir))) {
                            $found.Add($targetDir)
                        }
                    }
                } catch { }
            }
        } catch { }
    }

    # 3) 运行中的进程
    try {
        $proc = Get-Process -Name "Plain Craft Launcher 2" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path) {
            $procDir = Split-Path $proc.Path -Parent
            if ((Test-Path (Join-Path $procDir $script:ExeName)) -and (-not $found.Contains($procDir))) {
                $found.Add($procDir)
            }
        }
    } catch { }

    return $found
}

# ============================================================================
#  更新守卫核心：坏更新自动撤回，正常更新放行
# ============================================================================
function Get-PCLExeInfo {
    param([string]$PclDir)
    $exe = Join-Path $PclDir $script:ExeName
    if (-not (Test-Path $exe)) { return $null }
    $item = Get-Item $exe
    $verText = ($item.VersionInfo.FileVersion -replace '[^\d\.]', '')
    $ver = $null
    try { $ver = [version]$verText } catch { }
    return [pscustomobject]@{ Path = $exe; Item = $item; Version = $ver }
}

function Invoke-UpdateGuard {
    param([string]$PclDir, [switch]$Silent)
    $info = Get-PCLExeInfo -PclDir $PclDir
    if (-not $info) {
        Write-Log "更新守卫：未找到 PCL ($PclDir)" "Orange"
        return "未找到 PCL"
    }
    if (-not $info.Version) {
        Write-Log "更新守卫：无法识别版本号，跳过" "Orange"
        return "版本号无法识别"
    }
    $ver = $info.Version
    $isBad = $ver -ge $script:BadVersionMin

    if (-not $isBad) {
        # 正常更新：放行，什么都不动
        $msg = "当前版本 v$ver 正常，正常更新照常放行（守卫无需动作）"
        Write-Log "更新守卫：$msg" "LightGreen"
        return $msg
    }

    # 坏更新（砍掉 MC 下载）：自动撤回到备份
    Write-Log "更新守卫：检测到坏更新 v$ver（砍掉 MC 下载），准备撤回..." "Salmon"
    $backup = Get-ChildItem $PclDir -Filter "$($script:ExeName).backup_*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) {
        $msg = "检测到坏更新 v$ver，但没有备份。请打开工具点「一键恢复旧版本」。"
        Write-Log "更新守卫：$msg" "Red"
        return $msg
    }
    try {
        $info.Item.IsReadOnly = $false
        $backupVer = $backup.VersionInfo.FileVersion
        Copy-Item $backup.FullName $info.Path -Force
        $msg = "坏更新 v$ver 已自动撤回 → v$backupVer（正常更新不受影响）"
        Write-Log "更新守卫：$msg" "LightGreen"
        return $msg
    } catch {
        $msg = "撤回失败：$($_.Exception.Message)"
        Write-Log "更新守卫：$msg" "Red"
        return $msg
    }
}

function Set-AutoGuard {
    param([bool]$Enable)
    try {
        if ($Enable) {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($script:StartupLnk)
            $sc.TargetPath = "powershell.exe"
            $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:ScriptPath`" -Guard"
            $sc.WorkingDirectory = Split-Path $script:ScriptPath -Parent
            $sc.Description = "PCL 更新守卫：自动撤回砍掉 MC 下载的坏更新"
            $sc.Save()
            Write-Log "开机自动守卫：已开启（登录时静默检查）" "LightGreen"
        } else {
            if (Test-Path $script:StartupLnk) { Remove-Item $script:StartupLnk -Force }
            Write-Log "开机自动守卫：已关闭" "Yellow"
        }
        return $true
    } catch {
        Write-Log "设置开机守卫失败：$($_.Exception.Message)" "Orange"
        return $false
    }
}

function Set-FullLock {
    param([bool]$Lock, [string]$PclDir)
    $info = Get-PCLExeInfo -PclDir $PclDir
    if (-not $info) { return }
    try {
        $info.Item.IsReadOnly = $Lock
        if ($Lock) {
            Write-Log "完全锁定更新：已开启（exe 只读，禁止一切更新）" "Yellow"
        } else {
            Write-Log "完全锁定更新：已关闭（正常更新放行，坏更新由守卫撤回）" "LightGreen"
        }
    } catch {
        Write-Log "设置锁定失败：$($_.Exception.Message)" "Orange"
    }
}

# ============================================================================
#  静默守卫模式（开机自启 / 手动 -Guard）
# ============================================================================
if ($Guard) {
    $cfg = Get-ToolConfig
    $pclDir = $cfg.PclDir
    if (-not $pclDir -or -not (Test-Path (Join-Path $pclDir $script:ExeName))) {
        $found = Find-PCLInstallations
        if ($found.Count -gt 0) { $pclDir = $found[0] }
    }
    if (-not $pclDir) { exit 0 }

    $result = Invoke-UpdateGuard -PclDir $pclDir -Silent

    # 桌面右下角气泡提示（仅守卫有动作或坏更新时提醒）
    if ($result -match "撤回|坏更新|备份") {
        try {
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Icon = [System.Drawing.SystemIcons]::Information
            $ni.Visible = $true
            $ni.ShowBalloonTip(6000, "PCL 更新守卫", $result, [System.Windows.Forms.ToolTipIcon]::Info)
            Start-Sleep -Seconds 7
            $ni.Dispose()
        } catch { }
    }
    exit 0
}

# ============================================================================
#  下载
# ============================================================================
function Get-PCLZip {
    param([string]$DestPath)
    foreach ($url in $script:DownloadUrls) {
        $shortUrl = $url -replace '^https?://', '' -replace '/.*$', ''
        Write-Log "尝试下载: $shortUrl ..." "DarkGray"
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $url -OutFile $DestPath -TimeoutSec 120 -UseBasicParsing
            try {
                $fs = [System.IO.File]::OpenRead($DestPath)
                $reader = New-Object System.IO.BinaryReader($fs)
                $magic = $reader.ReadBytes(2)
                $reader.Close()
                $fs.Close()
                if ($magic[0] -ne 0x50 -or $magic[1] -ne 0x4B) {
                    Write-Log "下载内容不是有效的 zip 文件" "Orange"
                    continue
                }
            } catch {
                Write-Log "文件验证失败" "Orange"
                continue
            }
            $sizeMB = [Math]::Round((Get-Item $DestPath).Length / 1MB, 1)
            Write-Log "下载成功！($sizeMB MB)" "LightGreen"
            return $true
        } catch {
            $errMsg = $_.Exception.Message
            if ($errMsg.Length -gt 80) { $errMsg = $errMsg.Substring(0, 80) + "..." }
            Write-Log "失败: $errMsg" "Salmon"
        }
    }
    return $false
}

# ============================================================================
#  恢复主流程
# ============================================================================
function Invoke-PCLRestore {
    param([string]$PclDir)
    $currentExe = Join-Path $PclDir $script:ExeName
    if (-not (Test-Path $currentExe)) {
        Write-Log "错误：未找到 $script:ExeName" "Red"
        return $false
    }
    if (Test-Path $script:TempBase) {
        Remove-Item $script:TempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $script:TempBase -Force | Out-Null

    try {
        # ---- 1. 下载 ----
        Set-Status "步骤 1/4：正在下载 PCL $($script:OldPCLVersion)..." 5
        Write-Log "===== 开始恢复 PCL $($script:OldPCLVersion) =====" "Yellow"
        $zipPath = Join-Path $script:TempBase "pcl_tag.zip"
        if (-not (Get-PCLZip -DestPath $zipPath)) {
            Write-Log "" "White"
            Write-Log "所有下载源均失败！" "Red"
            Write-Log "请检查网络，或使用 VPN 后重试。" "Orange"
            return $false
        }

        # ---- 2. 解压 ----
        Set-Status "步骤 2/4：正在解压..." 30
        Write-Log "正在解压..." "DarkGray"
        $extractDir = Join-Path $script:TempBase "extract"
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
        $innerZip = Get-ChildItem $extractDir -Recurse -Filter "最新正式版.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $innerZip) {
            Write-Log "错误：未找到 最新正式版.zip" "Red"
            return $false
        }
        Write-Log "找到 PCL 发布包" "LightGreen"
        $innerDir = Join-Path $script:TempBase "inner"
        Expand-Archive -Path $innerZip.FullName -DestinationPath $innerDir -Force -ErrorAction Stop
        $newExe = Get-ChildItem $innerDir -Recurse -Filter $script:ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $newExe) {
            Write-Log "错误：未找到 PCL 主程序" "Red"
            return $false
        }
        $newVer = $newExe.VersionInfo.FileVersion
        $curItem = Get-Item $currentExe
        $curVer = $curItem.VersionInfo.FileVersion
        Write-Log "当前版本: $curVer → 目标版本: $newVer" "Cyan"

        # ---- 3. 备份 & 替换 ----
        Set-Status "步骤 3/4：正在备份并替换..." 60
        Write-Log "正在备份当前版本..." "DarkGray"
        $curItem.IsReadOnly = $false
        $safeVer = ($curVer -replace '[^\d\.]', '_')
        $backupPath = Join-Path $PclDir "$($script:ExeName).backup_$safeVer"
        Copy-Item $currentExe $backupPath -Force -ErrorAction Stop
        Write-Log "已备份: $(Split-Path $backupPath -Leaf)" "LightGreen"
        Write-Log "正在替换为 $script:OldPCLVersion ..." "DarkGray"
        Copy-Item $newExe.FullName $currentExe -Force -ErrorAction Stop

        # ---- 4. 更新策略 ----
        Set-Status "步骤 4/4：应用更新策略..." 90
        $cfg = Get-ToolConfig
        if ($cfg.LockAll) {
            (Get-Item $currentExe).IsReadOnly = $true
            Write-Log "已完全锁定更新（exe 只读，禁止一切更新）" "Yellow"
        } else {
            (Get-Item $currentExe).IsReadOnly = $false
            Write-Log "更新策略：正常更新放行；砍掉 MC 下载的坏更新将由守卫自动撤回" "LightGreen"
        }

        # ---- 完成 ----
        Set-Status "恢复完成！" 100
        Write-Log "" "White"
        Write-Log "========================================" "LightGreen"
        Write-Log "  恢复成功！PCL 已回退到 $script:OldPCLVersion" "LightGreen"
        Write-Log "  MC 下载功能已恢复，可以正常使用了！" "LightGreen"
        Write-Log "========================================" "LightGreen"
        Write-Log "" "White"
        Write-Log "提示：备份文件名为 $script:ExeName.backup_*，想还原时改回原名即可" "DarkGray"
        return $true

    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "错误: $errMsg" "Red"
        $backupFile = Get-ChildItem $PclDir -Filter "$($script:ExeName).backup_*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($backupFile -and -not (Test-Path $currentExe)) {
            Write-Log "正在尝试回滚..." "Orange"
            Copy-Item $backupFile.FullName $currentExe -Force
            Write-Log "已回滚到备份版本" "LightGreen"
        }
        return $false
    } finally {
        Remove-Item $script:TempBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
#  创建 UI
# ============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "PCL 一键恢复工具 v$script:AppVersion"
$form.Size = New-Object System.Drawing.Size(560, 660)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 250)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Icon = [System.Drawing.SystemIcons]::Information

# --- 标题 ---
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "PCL 一键恢复工具"
$titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(33, 102, 214)
$titleLabel.Location = New-Object System.Drawing.Point(20, 15)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "回退 PCL2 到 $script:OldPCLVersion，恢复 MC 下载功能"
$subtitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$subtitleLabel.ForeColor = [System.Drawing.Color]::Gray
$subtitleLabel.Location = New-Object System.Drawing.Point(22, 52)
$subtitleLabel.AutoSize = $true
$form.Controls.Add($subtitleLabel)

# --- 分隔线 ---
$sep1 = New-Object System.Windows.Forms.Label
$sep1.BorderStyle = "Fixed3D"
$sep1.AutoSize = $false
$sep1.Size = New-Object System.Drawing.Size(510, 2)
$sep1.Location = New-Object System.Drawing.Point(20, 80)
$form.Controls.Add($sep1)

# --- PCL 路径 ---
$pathCaption = New-Object System.Windows.Forms.Label
$pathCaption.Text = "PCL 安装位置："
$pathCaption.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$pathCaption.Location = New-Object System.Drawing.Point(20, 96)
$pathCaption.AutoSize = $true
$form.Controls.Add($pathCaption)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(20, 122)
$pathBox.Size = New-Object System.Drawing.Size(360, 26)
$pathBox.ReadOnly = $true
$pathBox.BackColor = [System.Drawing.Color]::White
$pathBox.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$pathBox.BorderStyle = "FixedSingle"
$form.Controls.Add($pathBox)

$browseBtn = New-Object System.Windows.Forms.Button
$browseBtn.Text = "浏览..."
$browseBtn.Location = New-Object System.Drawing.Point(390, 120)
$browseBtn.Size = New-Object System.Drawing.Size(65, 30)
$browseBtn.FlatStyle = "Flat"
$browseBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$browseBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($browseBtn)

$detectBtn = New-Object System.Windows.Forms.Button
$detectBtn.Text = "检测"
$detectBtn.Location = New-Object System.Drawing.Point(463, 120)
$detectBtn.Size = New-Object System.Drawing.Size(57, 30)
$detectBtn.FlatStyle = "Flat"
$detectBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$detectBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($detectBtn)

# --- 恢复按钮 ---
$restoreBtn = New-Object System.Windows.Forms.Button
$restoreBtn.Text = "一 键 恢 复 旧 版 本"
$restoreBtn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$restoreBtn.Location = New-Object System.Drawing.Point(115, 168)
$restoreBtn.Size = New-Object System.Drawing.Size(330, 52)
$restoreBtn.BackColor = [System.Drawing.Color]::FromArgb(33, 102, 214)
$restoreBtn.ForeColor = [System.Drawing.Color]::White
$restoreBtn.FlatStyle = "Flat"
$restoreBtn.FlatAppearance.BorderSize = 0
$restoreBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($restoreBtn)

# --- 状态与进度 ---
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "状态：就绪"
$statusLabel.Location = New-Object System.Drawing.Point(20, 235)
$statusLabel.AutoSize = $true
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$form.Controls.Add($statusLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 258)
$progressBar.Size = New-Object System.Drawing.Size(500, 20)
$progressBar.Style = "Continuous"
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$form.Controls.Add($progressBar)

# --- 更新守卫（v1.1 新增） ---
$guardGroup = New-Object System.Windows.Forms.GroupBox
$guardGroup.Text = "更新守卫"
$guardGroup.Location = New-Object System.Drawing.Point(20, 292)
$guardGroup.Size = New-Object System.Drawing.Size(500, 128)
$guardGroup.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Controls.Add($guardGroup)

$guardBtn = New-Object System.Windows.Forms.Button
$guardBtn.Text = "检查更新安全"
$guardBtn.Location = New-Object System.Drawing.Point(14, 26)
$guardBtn.Size = New-Object System.Drawing.Size(135, 32)
$guardBtn.FlatStyle = "Flat"
$guardBtn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
$guardBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$guardGroup.Controls.Add($guardBtn)

$guardPolicy = New-Object System.Windows.Forms.Label
$guardPolicy.Text = "策略：正常更新照常放行，只有砍掉 MC 下载的坏更新（≥2.99）自动撤回"
$guardPolicy.Location = New-Object System.Drawing.Point(158, 22)
$guardPolicy.Size = New-Object System.Drawing.Size(330, 40)
$guardPolicy.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$guardGroup.Controls.Add($guardPolicy)

$chkAutoGuard = New-Object System.Windows.Forms.CheckBox
$chkAutoGuard.Text = "开机自动守卫（登录时静默检查，推荐）"
$chkAutoGuard.Location = New-Object System.Drawing.Point(14, 66)
$chkAutoGuard.AutoSize = $true
$guardGroup.Controls.Add($chkAutoGuard)

$chkLockAll = New-Object System.Windows.Forms.CheckBox
$chkLockAll.Text = "完全锁定更新（禁止一切更新，最保险）"
$chkLockAll.Location = New-Object System.Drawing.Point(14, 96)
$chkLockAll.AutoSize = $true
$guardGroup.Controls.Add($chkLockAll)

# --- 日志 ---
$logCaption = New-Object System.Windows.Forms.Label
$logCaption.Text = "日志："
$logCaption.Location = New-Object System.Drawing.Point(20, 432)
$logCaption.AutoSize = $true
$form.Controls.Add($logCaption)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(20, 452)
$logBox.Size = New-Object System.Drawing.Size(500, 125)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(25, 28, 35)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(210, 210, 210)
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$logBox.BorderStyle = "FixedSingle"
$logBox.DetectUrls = $false
$form.Controls.Add($logBox)

# --- 底部提示 ---
$sep2 = New-Object System.Windows.Forms.Label
$sep2.BorderStyle = "Fixed3D"
$sep2.AutoSize = $false
$sep2.Size = New-Object System.Drawing.Size(510, 2)
$sep2.Location = New-Object System.Drawing.Point(20, 589)
$form.Controls.Add($sep2)

$tipLabel = New-Object System.Windows.Forms.Label
$tipLabel.Text = "恢复前会自动备份当前版本 | 备份文件名含 backup 可随时还原 | MIT 开源"
$tipLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$tipLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$tipLabel.Location = New-Object System.Drawing.Point(20, 599)
$tipLabel.AutoSize = $true
$form.Controls.Add($tipLabel)

# ============================================================================
#  事件处理
# ============================================================================

# --- 检测按钮 ---
$detectBtn.Add_Click({
    Write-Log "正在检测 PCL 安装位置..." "Yellow"
    $found = Find-PCLInstallations
    if ($found.Count -gt 0) {
        $pathBox.Text = $found[0]
        Write-Log "找到 $($found.Count) 个 PCL 安装：" "Yellow"
        foreach ($p in $found) {
            Write-Log "  -> $p" "Cyan"
        }
        Write-Log "已选择: $($found[0])" "LightGreen"
        Save-ToolConfig -PclDir $pathBox.Text -AutoGuard $chkAutoGuard.Checked -LockAll $chkLockAll.Checked
    } else {
        Write-Log "未找到 PCL，请点击浏览手动选择" "Orange"
    }
})

# --- 浏览按钮 ---
$browseBtn.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "选择包含 Plain Craft Launcher 2.exe 的文件夹"
    $dialog.ShowNewFolderButton = $false
    if ($pathBox.Text -and (Test-Path $pathBox.Text)) {
        $dialog.SelectedPath = $pathBox.Text
    }
    if ($dialog.ShowDialog() -eq "OK") {
        $exe = Join-Path $dialog.SelectedPath $script:ExeName
        if (Test-Path $exe) {
            $pathBox.Text = $dialog.SelectedPath
            Write-Log "手动选择: $($dialog.SelectedPath)" "LightGreen"
            Save-ToolConfig -PclDir $pathBox.Text -AutoGuard $chkAutoGuard.Checked -LockAll $chkLockAll.Checked
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "该文件夹中没有找到 $script:ExeName`n`n请选择包含 PCL 主程序的文件夹。",
                "未找到 PCL", "OK", "Warning"
            ) | Out-Null
        }
    }
})

# --- 检查更新安全（守卫手动触发） ---
$guardBtn.Add_Click({
    $pclDir = $pathBox.Text.Trim()
    if (-not $pclDir -or -not (Test-Path (Join-Path $pclDir $script:ExeName))) {
        [System.Windows.Forms.MessageBox]::Show("请先选择有效的 PCL 安装位置。", "提示", "OK", "Information") | Out-Null
        return
    }
    $guardBtn.Enabled = $false
    Write-Log "" "White"
    Write-Log "----- 手动检查更新安全 -----" "Yellow"
    try {
        $result = Invoke-UpdateGuard -PclDir $pclDir
        [System.Windows.Forms.MessageBox]::Show($result, "更新守卫", "OK", "Information") | Out-Null
    } finally {
        $guardBtn.Enabled = $true
    }
})

# --- 开机自动守卫 ---
$chkAutoGuard.Add_CheckedChanged({
    $ok = Set-AutoGuard -Enable $chkAutoGuard.Checked
    Save-ToolConfig -PclDir $pathBox.Text -AutoGuard $chkAutoGuard.Checked -LockAll $chkLockAll.Checked
})

# --- 完全锁定更新 ---
$chkLockAll.Add_CheckedChanged({
    $pclDir = $pathBox.Text.Trim()
    if ($pclDir -and (Test-Path (Join-Path $pclDir $script:ExeName))) {
        Set-FullLock -Lock $chkLockAll.Checked -PclDir $pclDir
    }
    Save-ToolConfig -PclDir $pathBox.Text -AutoGuard $chkAutoGuard.Checked -LockAll $chkLockAll.Checked
})

# --- 恢复按钮 ---
$restoreBtn.Add_Click({
    $pclDir = $pathBox.Text.Trim()
    if (-not $pclDir -or -not (Test-Path (Join-Path $pclDir $script:ExeName))) {
        [System.Windows.Forms.MessageBox]::Show(
            "请先选择有效的 PCL 安装位置。`n`n可以点击 [检测] 自动查找，或 [浏览] 手动选择。",
            "提示", "OK", "Information"
        ) | Out-Null
        return
    }

    $running = Get-Process -Name "Plain Craft Launcher 2" -ErrorAction SilentlyContinue
    if ($running) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "检测到 PCL 正在运行！`n`n恢复前需要关闭 PCL。`n`n是否自动关闭？",
            "PCL 正在运行", "YesNo", "Warning"
        )
        if ($r -eq "Yes") {
            try {
                $running | Stop-Process -Force -ErrorAction Stop
                Start-Sleep -Seconds 2
                Write-Log "已关闭 PCL 进程" "Yellow"
            } catch {
                [System.Windows.Forms.MessageBox]::Show("关闭 PCL 失败，请手动关闭后重试。", "错误", "OK", "Error") | Out-Null
                return
            }
        } else {
            Write-Log "操作已取消" "Orange"
            return
        }
    }

    $curVer = (Get-Item (Join-Path $pclDir $script:ExeName)).VersionInfo.FileVersion
    $r = [System.Windows.Forms.MessageBox]::Show(
        "即将恢复 PCL 到 $script:OldPCLVersion`n`n" +
        "安装位置：`n$pclDir`n`n" +
        "当前版本 $curVer 会被自动备份。`n`n确定继续？",
        "确认恢复", "YesNo", "Question"
    )
    if ($r -ne "Yes") {
        Write-Log "操作已取消" "Orange"
        return
    }

    $restoreBtn.Enabled = $false
    $detectBtn.Enabled = $false
    $browseBtn.Enabled = $false
    $guardBtn.Enabled = $false
    $logBox.Clear()
    Save-ToolConfig -PclDir $pclDir -AutoGuard $chkAutoGuard.Checked -LockAll $chkLockAll.Checked

    try {
        $success = Invoke-PCLRestore -PclDir $pclDir
        if ($success) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "恢复成功！`n`nPCL 已回退到 $script:OldPCLVersion，MC 下载功能已恢复。`n`n是否立即打开 PCL？",
                "完成", "YesNo", "Information"
            )
            if ($r -eq "Yes") {
                Start-Process (Join-Path $pclDir $script:ExeName)
            }
        }
    } finally {
        $restoreBtn.Enabled = $true
        $detectBtn.Enabled = $true
        $browseBtn.Enabled = $true
        $guardBtn.Enabled = $true
    }
})

# ============================================================================
#  初始化
# ============================================================================
Write-Log "PCL 一键恢复工具 v$script:AppVersion 已启动" "Yellow"
Write-Log "正在自动检测 PCL 安装位置..." "DarkGray"

$cfg = Get-ToolConfig
$chkAutoGuard.Checked = [bool]$cfg.AutoGuard
$chkLockAll.Checked = [bool]$cfg.LockAll

$found = Find-PCLInstallations
if ($found.Count -gt 0) {
    $pathBox.Text = $found[0]
    Write-Log "检测到 PCL: $($found[0])" "LightGreen"
    if ($cfg.PclDir -and (Test-Path (Join-Path $cfg.PclDir $script:ExeName))) {
        $pathBox.Text = $cfg.PclDir
        Write-Log "使用上次选择: $($cfg.PclDir)" "Cyan"
    }
} elseif ($cfg.PclDir -and (Test-Path (Join-Path $cfg.PclDir $script:ExeName))) {
    $pathBox.Text = $cfg.PclDir
    Write-Log "使用上次选择: $($cfg.PclDir)" "Cyan"
} else {
    Write-Log "未自动检测到 PCL，请点击浏览手动选择" "Orange"
}

Write-Log "更新策略：正常更新放行，坏更新（≥$($script:BadVersionMin)）自动撤回" "LightGreen"
if (Test-Path $script:StartupLnk) {
    Write-Log "开机自动守卫：已启用" "LightGreen"
}
Write-Log "准备就绪，点击按钮开始恢复" "Gray"

# ============================================================================
#  显示窗体
# ============================================================================
[System.Windows.Forms.Application]::Run($form)
