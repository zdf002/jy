# ==============================================
# 软件自动更新器
# 将以下变量替换为你的实际信息
# ==============================================

param(
    [string]$LocalPath = $PSScriptRoot,          # 软件安装目录
    [string]$RepoOwner = "zdf002",        # 替换：你的GitHub用户名
    [string]$RepoName = "jy",        # 替换：你的仓库名
    [string]$SoftwareExe = "updater.exe",  # 替换：你的软件主程序名
    [switch]$Silent = $false                     # 静默模式，不显示界面
)

# ==============================================
# 配置区 - 根据实际情况修改
# ==============================================
$Config = @{
    VersionFile = "version.txt"
    BackupExt = ".bak"
    TempDir = $env:TEMP
    GitHubApi = "https://api.github.com"
    UserAgent = "SoftwareUpdater/1.0"
    Timeout = 30  # 秒
}

# ==============================================
# 工具函数
# ==============================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = "White"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    if (-not $Silent) {
        switch ($Level) {
            "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
            "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
            "INFO"    { Write-Host $logMessage -ForegroundColor Cyan }
            default   { Write-Host $logMessage -ForegroundColor $Color }
        }
    }

    # 同时写入日志文件
    $logMessage | Out-File -FilePath "$LocalPath\updater.log" -Append -Encoding UTF8
}

function Test-InternetConnection {
    try {
        $test = Test-NetConnection -ComputerName "github.com" -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
        return $test
    }
    catch {
        return $false
    }
}

function Get-CurrentVersion {
    $versionPath = Join-Path $LocalPath $Config.VersionFile
    if (Test-Path $versionPath) {
        try {
            $version = (Get-Content $versionPath -Raw -ErrorAction Stop).Trim()
            if ($version -match '^v?\d+\.\d+\.\d+') {
                return $version
            }
        }
        catch {
            Write-Log "读取版本文件失败: $($_.Exception.Message)" "WARNING"
        }
    }
    return "v0.0.0"
}

function Get-LatestReleaseInfo {
    $apiUrl = "$($Config.GitHubApi)/repos/$RepoOwner/$RepoName/releases/latest"

    try {
        $headers = @{
            "User-Agent" = $Config.UserAgent
            "Accept" = "application/vnd.github.v3+json"
        }

        # 如果有私有仓库，需要token
        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "token $env:GITHUB_TOKEN"
        }

        Write-Log "正在获取最新版本信息..."
        $response = Invoke-RestMethod -Uri $apiUrl `
            -Method GET `
            -Headers $headers `
            -TimeoutSec $Config.Timeout `
            -ErrorAction Stop

        return @{
            Version = $response.tag_name
            Assets = $response.assets
            ReleaseUrl = $response.html_url
            PublishedAt = $response.published_at
        }
    }
    catch {
        Write-Log "获取版本信息失败: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Find-Asset {
    param(
        [array]$Assets,
        [string]$Pattern
    )

    foreach ($asset in $Assets) {
        if ($asset.name -like $Pattern) {
            return $asset
        }
    }
    return $null
}

function Download-Asset {
    param(
        [string]$Url,
        [string]$OutputPath
    )

    try {
        Write-Log "正在下载: $Url"

        $headers = @{
            "User-Agent" = $Config.UserAgent
        }

        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "token $env:GITHUB_TOKEN"
        }

        Invoke-WebRequest -Uri $Url `
            -OutFile $OutputPath `
            -Headers $headers `
            -TimeoutSec $Config.Timeout `
            -ErrorAction Stop

        if (Test-Path $OutputPath) {
            Write-Log "下载完成: $OutputPath" "SUCCESS"
            return $true
        }
        else {
            Write-Log "下载文件不存在" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "下载失败: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Stop-Software {
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($SoftwareExe)

    try {
        $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
        if ($processes) {
            Write-Log "正在停止 $processName..."
            $processes | Stop-Process -Force -ErrorAction SilentlyContinue

            # 等待进程退出
            $maxWait = 10  # 最多等待10秒
            for ($i = 0; $i -lt $maxWait; $i++) {
                $stillRunning = Get-Process -Name $processName -ErrorAction SilentlyContinue
                if (-not $stillRunning) {
                    Write-Log "程序已停止" "SUCCESS"
                    Start-Sleep -Seconds 1
                    return $true
                }
                Start-Sleep -Seconds 1
            }
            Write-Log "程序停止超时" "WARNING"
        }
    }
    catch {
        Write-Log "停止程序失败: $($_.Exception.Message)" "WARNING"
    }

    return $false
}

function Backup-Files {
    param([string]$Path)

    if (Test-Path $Path) {
        $backupPath = "$Path$($Config.BackupExt)"
        try {
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force -Recurse -ErrorAction SilentlyContinue
            }
            Copy-Item $Path $backupPath -Recurse -Force
            Write-Log "已创建备份: $backupPath"
            return $true
        }
        catch {
            Write-Log "备份失败: $($_.Exception.Message)" "WARNING"
        }
    }
    return $false
}

# ==============================================
# 主更新流程
# ==============================================
function Start-UpdateProcess {
    Write-Log "=== 开始检查更新 ==="
    Write-Log "软件目录: $LocalPath"
    Write-Log "仓库: $RepoOwner/$RepoName"

    # 检查网络连接
    if (-not (Test-InternetConnection)) {
        Write-Log "网络连接失败，无法检查更新" "ERROR"
        if (-not $Silent) {
            Read-Host "按回车键启动现有版本"
        }
        return $false
    }

    # 获取版本信息
    $currentVersion = Get-CurrentVersion
    Write-Log "当前版本: $currentVersion"

    $releaseInfo = Get-LatestReleaseInfo
    if (-not $releaseInfo) {
        Write-Log "无法获取最新版本信息" "ERROR"
        return $false
    }

    $latestVersion = $releaseInfo.Version
    Write-Log "最新版本: $latestVersion"

    # 版本比较
    if ($currentVersion -eq $latestVersion) {
        Write-Log "已经是最新版本" "SUCCESS"
        return $true
    }

    # 查找可执行文件资源
    $exePattern = "*$SoftwareExe"
    $exeAsset = Find-Asset -Assets $releaseInfo.Assets -Pattern $exePattern

    if (-not $exeAsset) {
        Write-Log "未找到可执行文件资源" "ERROR"
        return $false
    }

    # 询问用户（非静默模式）
    if (-not $Silent) {
        Write-Host "`n=== 发现新版本 ===" -ForegroundColor Yellow
        Write-Host "当前版本: $currentVersion" -ForegroundColor White
        Write-Host "最新版本: $latestVersion" -ForegroundColor Green
        Write-Host "发布时间: $($releaseInfo.PublishedAt)" -ForegroundColor White
        Write-Host "更新说明: $($releaseInfo.ReleaseUrl)" -ForegroundColor Cyan
        Write-Host "`n是否立即更新到 $latestVersion？" -ForegroundColor Yellow

        $choice = $null
        while ($choice -notin @('Y', 'N')) {
            $choice = Read-Host "请选择 (Y=更新, N=跳过)"
        }

        if ($choice -eq 'N') {
            Write-Log "用户取消更新" "INFO"
            return $false
        }
    }

    # 开始更新
    Write-Log "开始更新到 $latestVersion..."

    # 1. 停止运行的程序
    Stop-Software | Out-Null

    # 2. 备份当前版本
    $exePath = Join-Path $LocalPath $SoftwareExe
    Backup-Files -Path $exePath

    # 3. 下载新版本
    $tempFile = Join-Path $Config.TempDir "$SoftwareExe.$latestVersion"
    if (Test-Path $tempFile) {
        Remove-Item $tempFile -Force
    }

    if (-not (Download-Asset -Url $exeAsset.browser_download_url -OutputPath $tempFile)) {
        Write-Log "更新失败" "ERROR"
        return $false
    }

    # 4. 替换文件
    try {
        # 删除旧文件
        if (Test-Path $exePath) {
            Remove-Item $exePath -Force -ErrorAction Stop
        }

        # 移动新文件
        Move-Item $tempFile $exePath -Force -ErrorAction Stop

        # 更新版本号
        $latestVersion | Out-File -FilePath (Join-Path $LocalPath $Config.VersionFile) `
            -Encoding UTF8 -Force

        Write-Log "更新完成！" "SUCCESS"
        Write-Log "新版本已安装: $latestVersion"

        # 5. 启动新版本
        if (Test-Path $exePath) {
            Write-Log "正在启动新版本..."
            Start-Process $exePath -WorkingDirectory $LocalPath
            return $true
        }
        else {
            Write-Log "程序文件不存在，启动失败" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "文件替换失败: $($_.Exception.Message)" "ERROR"

        # 尝试恢复备份
        $backupPath = "$exePath$($Config.BackupExt)"
        if (Test-Path $backupPath) {
            Write-Log "正在恢复备份..."
            Copy-Item $backupPath $exePath -Force
        }

        return $false
    }
}

# ==============================================
# 主程序入口
# ==============================================

# 检查PowerShell版本
if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host "需要PowerShell 3.0或更高版本" -ForegroundColor Red
    exit 1
}

# 如果是首次运行，可能没有版本文件
if (-not (Test-Path (Join-Path $LocalPath $Config.VersionFile))) {
    "v0.0.0" | Out-File -FilePath (Join-Path $LocalPath $Config.VersionFile) -Encoding UTF8
}

try {
    # 执行更新检查
    $result = Start-UpdateProcess

    if (-not $result -and -not $Silent) {
        # 如果更新失败或取消，启动现有版本
        $exePath = Join-Path $LocalPath $SoftwareExe
        if (Test-Path $exePath) {
            Write-Log "启动现有版本..."
            Start-Process $exePath -WorkingDirectory $LocalPath
        }
        else {
            Write-Log "程序文件不存在" "ERROR"
            if (-not $Silent) {
                Read-Host "按回车键退出"
            }
        }
    }
}
catch {
    Write-Log "更新过程中发生错误: $($_.Exception.Message)" "ERROR"
    Write-Log "错误详情: $($_.ScriptStackTrace)" "ERROR"

    if (-not $Silent) {
        Read-Host "按回车键退出"
    }
}

# 如果是静默模式，只记录日志
if ($Silent) {
    exit 0
}