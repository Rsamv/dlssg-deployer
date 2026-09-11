#requires -Version 5.1
<#
    DLSSG Native 0.2.4 - 一键部署 / 管理工具
    ------------------------------------------------------------
    - 检测当前 NVIDIA 显卡架构 (SM75 / SM86) 与驱动版本
    - 自动扫描 Steam / Epic / GOG / 常见目录，找出支持
      DLSS 帧生成 (目录内带 nvngx_dlssg.dll) 的游戏
    - 支持手动添加游戏目录
    - 安装 / 更新：将代理 DLL 与 dlssg_sm86.ini 安装到游戏目录
    - 卸载：仅移除本项目的代理 DLL 与 INI，可恢复备份
    - 档位切换：精确 (HardwareBilinear=0) / 性能 (HardwareBilinear=1)
    ------------------------------------------------------------
#>
[CmdletBinding()]
param(
    [switch]$NoPause,
    [switch]$ListOnly,
    [ValidateSet('Exact', 'Performance')]
    [string]$Preset,
    [switch]$Uninstall,
    [switch]$SwitchPreset,
    [string]$RepoUrl,
    [string[]]$GamePath
)

$ErrorActionPreference = 'Stop'

# ---- 控制台使用 UTF-8，保证中文正常显示 ----
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch { }

$script:Root          = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ProjectUrl    = 'https://github.com/sdli1995/dlssg_for_sm86'
$script:RepoOwner     = 'sdli1995'
$script:RepoName      = 'dlssg_for_sm86'
$script:RepoBranch    = 'main'
$script:PackageRoot   = $null
$script:ProxyDefault  = $null
$script:IniSource     = $null
$script:AltDir        = $null
$script:AltNames      = @('winmm.dll', 'dinput8.dll', 'winhttp.dll', 'dxgi.dll')
$script:AllProxyNames = @('version.dll') + $script:AltNames
$script:MinDriver     = 500.0
$script:SignerMatch   = 'DLSSG Native Project'
$script:DownloadTimeoutSec = 120
$script:MaxScanDepth  = 8

$script:Gpu             = $null
$script:Router          = $null
$script:GpuState        = 'Unknown'
$script:Games           = @()
$script:PresetMode      = if ($Preset) { $Preset } else { $null }
$script:KnownProxyHashes = @{}

# ============================================================
#  输出辅助
# ============================================================
function Write-Head([string]$text) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}
function Write-Ok([string]$t)    { Write-Host "  [OK]   $t"   -ForegroundColor Green }
function Write-Bad([string]$t)   { Write-Host "  [错误] $t"   -ForegroundColor Red }
function Write-Warn2([string]$t) { Write-Host "  [警告] $t"   -ForegroundColor Yellow }
function Write-Info([string]$t)  { Write-Host "  $t"          -ForegroundColor Gray }
function Write-Step([string]$t)  { Write-Host "  >> $t"       -ForegroundColor White }

# ============================================================
#  基础工具
# ============================================================
function Test-IsReparse([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# 拒绝把 Mod 写进系统目录或盘符根目录
function Test-SafeTargetDir([string]$dir) {
    try { $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\') } catch { return $false }
    $lower = $full.ToLower()
    if ($lower -match '^[a-z]:$') { return $false }

    $win = $null
    if ($env:windir) { $win = ([System.IO.Path]::GetFullPath($env:windir)).TrimEnd('\').ToLower() }
    if ($win -and ($lower -eq $win -or $lower.StartsWith($win + '\'))) { return $false }

    foreach ($e in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        $b = ([System.IO.Path]::GetFullPath($e)).TrimEnd('\').ToLower()
        if ($lower -eq $b) { return $false }
    }
    return $true
}

function Get-Sha256([string]$path) {
    try { return (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return $null }
}

# 校验代理 DLL 是否带有本项目的自签名证书（自签不受信任，但签名者必须匹配）
function Test-ProxySignature([string]$path) {
    try { $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop } catch { return $false }
    if ($sig.Status -eq 'NotSigned') { return $false }
    if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject -match [regex]::Escape($script:SignerMatch)) { return $true }
    return $false
}

function Initialize-KnownProxyHashes {
    $script:KnownProxyHashes = @{}
    $files = @($script:ProxyDefault)
    foreach ($n in $script:AltNames) { $files += (Join-Path $script:AltDir $n) }
    $files += (Join-Path $script:PackageRoot 'archive\version.dll')
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            $h = Get-Sha256 $f
            if ($h -and -not $script:KnownProxyHashes.ContainsKey($h)) { $script:KnownProxyHashes[$h] = $f }
        }
    }
}

function Test-GameRunning($entry) {
    if (-not $entry.MainExe) { return $false }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($entry.MainExe)
    if ([string]::IsNullOrWhiteSpace($base)) { return $false }
    return [bool](Get-Process -Name $base -ErrorAction SilentlyContinue)
}

# 修改/插入 INI 键值
function Set-IniLine([string]$text, [string]$key, [string]$value) {
    $lines = @($text -split "`r`n|`n")
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^[ \t]*' + [regex]::Escape($key) + '[ \t]*=')) {
            $lines[$i] = "$key=$value"
            $found = $true
            break
        }
    }
    if (-not $found) {
        $ci = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\[Compatibility\][ \t]*$') { $ci = $i; break }
        }
        if ($ci -ge 0) {
            $before = @($lines[0..$ci])
            $after = @()
            if ($ci + 1 -lt $lines.Count) { $after = @($lines[($ci + 1)..($lines.Count - 1)]) }
            $lines = $before + @("$key=$value") + $after
        } else {
            $lines = $lines + @('', '[Compatibility]', "$key=$value")
        }
    }
    return ($lines -join "`r`n")
}

# ============================================================
#  显卡 / 驱动检测
# ============================================================
function Convert-DriverVersion([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    $p = $v.Split('.')
    if ($p.Count -ge 4) {
        $tail = $p[2].Substring($p[2].Length - 1) + $p[3]
        if ($tail -match '^\d{4,6}$') { return ([double]$tail / 100.0) }
    }
    return $null
}

function Get-GpuInfo {
    $vcs = @()
    try { $vcs = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop } catch { }
    $nvidia = $vcs | Where-Object { $_.Name -match 'NVIDIA' }
    if (-not $nvidia) { return $null }

    $g         = $nvidia | Select-Object -First 1
    $name      = $g.Name
    $driverRaw = $g.DriverVersion
    $driver    = Convert-DriverVersion $driverRaw

    $series = '未知'
    $router = $null
    $state  = 'Unsupported'

    if ($name -match 'RTX\s*[Aa]\d{3}') {
        $series = 'Ampere'; $router = 'SM86'; $state = 'Supported'
    }
    elseif ($name -match 'RTX\s*30\d0') {
        $series = 'Ampere'; $router = 'SM86'; $state = 'Supported'
    }
    elseif ($name -match 'RTX\s*20\d0') {
        $series = 'Turing'; $router = 'SM75'; $state = 'Supported'
    }
    elseif ($name -match 'RTX\s*[45]0\d0') {
        $series = 'Ada/Blackwell'; $router = $null; $state = 'NativeFG'
    }
    elseif ($name -match 'GTX\s*16\d0') {
        $series = 'Turing (无 Tensor Core)'; $router = $null; $state = 'Unsupported'
    }

    return [pscustomobject]@{
        Name      = $name
        Series    = $series
        Router    = $router
        State     = $state
        DriverRaw = $driverRaw
        Driver    = $driver
    }
}

function Show-GpuReport {
    Write-Head '检测显卡与驱动'
    $g = Get-GpuInfo
    $script:Gpu = $g

    if (-not $g) {
        Write-Bad '未检测到 NVIDIA 显卡。'
        Write-Info '本 Mod 需要 NVIDIA 驱动提供的 NGX / NVAPI / CUDA 接口。'
        $script:GpuState = 'NoNvidia'
        return
    }

    Write-Info ("显卡型号 : {0}" -f $g.Name)
    Write-Info ("架构     : {0}" -f $g.Series)
    if ($g.Driver) {
        Write-Info ("驱动版本 : {0}  (原始: {1})" -f $g.Driver, $g.DriverRaw)
    } else {
        Write-Info ("驱动版本 : 无法解析 (原始: {0})" -f $g.DriverRaw)
    }

    switch ($g.State) {
        'Supported' {
            $script:Router   = $g.Router
            $script:GpuState = 'Supported'
            Write-Ok ("受支持：将使用 Router={0}" -f $g.Router)
            if ($g.Driver -and $g.Driver -lt $script:MinDriver) {
                Write-Warn2 ("驱动版本 {0} 较旧，建议升级到较新的 NVIDIA 驱动。" -f $g.Driver)
            }
        }
        'NativeFG' {
            $script:GpuState = 'NativeFG'
            Write-Warn2 '该显卡（RTX 40/50 系）原生支持 DLSS 帧生成，通常无需本 Mod。'
            Write-Info '仍可继续安装，但本 Mod 主要面向 RTX 20/30 系。'
        }
        'Unsupported' {
            $script:GpuState = 'Unsupported'
            Write-Warn2 '该显卡不在本 Mod 支持的架构范围内（RTX 20 系 = SM75，RTX 30 系 = SM86）。'
            Write-Info '继续安装可能无法生效，请谨慎。'
        }
    }
}

# ============================================================
#  游戏目录收集
# ============================================================
function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steamPath = $null
    try {
        $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch { }
    if (-not $steamPath) {
        try { $steamPath = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction Stop).InstallPath } catch { }
    }
    if ($steamPath) {
        $steamPath = $steamPath -replace '/', '\'
        $libs.Add($steamPath) | Out-Null
        $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            try {
                $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
                foreach ($m in [regex]::Matches($txt, '"path"\s*"([^"]+)"')) {
                    $p = $m.Groups[1].Value -replace '\\\\', '\' -replace '/', '\'
                    if ($p) { $libs.Add($p) | Out-Null }
                }
            } catch { }
        }
    }
    return ($libs | Select-Object -Unique)
}

function Get-EpicGameFolders {
    $list = New-Object System.Collections.Generic.List[string]
    $manifestDir = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-Path -LiteralPath $manifestDir) {
        Get-ChildItem -LiteralPath $manifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($j.InstallLocation) { $list.Add(($j.InstallLocation -replace '/', '\')) | Out-Null }
            } catch { }
        }
    }
    return $list
}

function Get-GogGameFolders {
    $list = New-Object System.Collections.Generic.List[string]
    $base = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games'
    if (Test-Path $base) {
        Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $p = (Get-ItemProperty -LiteralPath $_.PSPath -Name path -ErrorAction Stop).path
                if ($p) { $list.Add(($p -replace '/', '\')) | Out-Null }
            } catch { }
        }
    }
    return $list
}

function Get-CandidateGameFolders {
    $result = New-Object System.Collections.Generic.List[object]
    $seen   = @{}

    function Add-GameFolder([string]$folder, [string]$name) {
        if ([string]::IsNullOrWhiteSpace($folder)) { return }
        if (-not (Test-Path -LiteralPath $folder)) { return }
        $key = $folder.TrimEnd('\').ToLower()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $result.Add([pscustomobject]@{ Name = $name; Folder = $folder }) | Out-Null
    }

    foreach ($lib in (Get-SteamLibraries)) {
        $common = Join-Path $lib 'steamapps\common'
        if (Test-Path -LiteralPath $common) {
            Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Add-GameFolder $_.FullName $_.Name
            }
        }
    }
    foreach ($f in (Get-EpicGameFolders)) { Add-GameFolder $f (Split-Path -Leaf $f) }
    foreach ($f in (Get-GogGameFolders))  { Add-GameFolder $f (Split-Path -Leaf $f) }

    $commonNames = @('SteamLibrary\steamapps\common', 'Games', 'Game', 'Epic Games', 'GOG Games')
    $skipNames   = @(
        'windows', 'program files', 'program files (x86)', 'programdata', 'recovery',
        'perflogs', 'msocache', 'config.msi', '$winreagent', 'users', 'documents and settings',
        'intel', 'amd', 'nvidia', 'temp', 'tmp', 'node_modules', '.git', 'boot', 'efi',
        'system volume information', '$recycle.bin'
    )
    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
              Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($d in $drives) {
        foreach ($n in $commonNames) {
            $p = Join-Path $d.Root $n
            if (Test-Path -LiteralPath $p) {
                Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    Add-GameFolder $_.FullName $_.Name
                }
            }
        }
        # 盘符根目录下的独立游戏（免安装 / 第三方启动器）
        Get-ChildItem -LiteralPath $d.Root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($skipNames -contains $_.Name.ToLower()) { return }
            if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }
            Add-GameFolder $_.FullName $_.Name
        }
    }
    return $result
}

# 在游戏目录中查找 nvngx_dlssg.dll，返回安装目标目录
function Find-DlssgTarget([string]$folder) {
    try {
        $dlls = Get-ChildItem -LiteralPath $folder -Recurse -Depth $script:MaxScanDepth -Filter 'nvngx_dlssg.dll' -File -ErrorAction SilentlyContinue
    } catch { return $null }
    if (-not $dlls) { return $null }

    $dirs = $dlls | ForEach-Object { $_.DirectoryName } | Select-Object -Unique |
            Sort-Object { $_.Length }
    # 1) DLL 与 EXE 同目录（绝大多数游戏）
    foreach ($d in $dirs) {
        $exe = Get-ChildItem -LiteralPath $d -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { return $d }
    }
    # 2) DLL 位于子目录（如 UE 的 Streamline 插件）：取体积最大的主程序所在目录
    $mainExe = Get-ChildItem -LiteralPath $folder -Recurse -Depth $script:MaxScanDepth -Filter '*.exe' -File -ErrorAction SilentlyContinue |
               Sort-Object Length -Descending | Select-Object -First 1
    if ($mainExe) { return $mainExe.DirectoryName }
    # 3) 兜底：返回最浅的 DLL 目录
    return ($dirs | Select-Object -First 1)
}

# 查找已安装本 Mod 的目录（以 dlssg_sm86.ini 为标志）
function Find-InstalledTarget([string]$folder) {
    try {
        $inis = Get-ChildItem -LiteralPath $folder -Recurse -Depth $script:MaxScanDepth -Filter 'dlssg_sm86.ini' -File -ErrorAction SilentlyContinue
    } catch { return $null }
    if (-not $inis) { return $null }

    $dirs = $inis | ForEach-Object { $_.DirectoryName } | Select-Object -Unique
    foreach ($d in $dirs) {
        foreach ($name in $script:AllProxyNames) {
            $p = Join-Path $d $name
            if (Test-Path -LiteralPath $p) {
                $h = Get-Sha256 $p
                if ($h -and $script:KnownProxyHashes.ContainsKey($h)) { return $d }
            }
        }
    }
    return ($dirs | Select-Object -First 1)
}

function Get-MainExe([string]$dir) {
    $exes = Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -ErrorAction SilentlyContinue
    if (-not $exes) { return $null }
    return ($exes | Sort-Object Length -Descending | Select-Object -First 1).Name
}

function New-GameEntry([string]$name, [string]$targetDir, [string]$source) {
    return [pscustomobject]@{
        Name      = $name
        TargetDir = $targetDir
        MainExe   = (Get-MainExe $targetDir)
        Source    = $source
    }
}

function New-InstalledEntry([string]$name, [string]$targetDir) {
    $proxies = @()
    foreach ($pname in $script:AllProxyNames) {
        $p = Join-Path $targetDir $pname
        if (Test-Path -LiteralPath $p) {
            $h = Get-Sha256 $p
            if ($h -and $script:KnownProxyHashes.ContainsKey($h)) { $proxies += $pname }
        }
    }
    $backups = @(Get-ChildItem -LiteralPath $targetDir -Directory -Filter 'dlssg_sm86_backup_*' -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending)
    return [pscustomobject]@{
        Name      = $name
        TargetDir = $targetDir
        MainExe   = (Get-MainExe $targetDir)
        Proxies   = $proxies
        Backups   = $backups
        HasIni    = (Test-Path -LiteralPath (Join-Path $targetDir 'dlssg_sm86.ini'))
        Source    = '扫描'
    }
}

function Add-GameIfUnique($entry) {
    if (-not $entry) { return }
    $key = $entry.TargetDir.TrimEnd('\').ToLower()
    foreach ($g in $script:Games) {
        if ($g.TargetDir.TrimEnd('\').ToLower() -eq $key) { return }
    }
    $script:Games += $entry
}

# ============================================================
#  扫描流程
# ============================================================
function Invoke-ScanGames {
    Write-Head '扫描支持 DLSS 帧生成的游戏'
    $candidates = Get-CandidateGameFolders
    $total = $candidates.Count
    Write-Info ("发现 {0} 个候选游戏目录，正在检查 nvngx_dlssg.dll ..." -f $total)

    $i = 0
    foreach ($c in $candidates) {
        $i++
        $pct = if ($total -gt 0) { [int](($i / $total) * 100) } else { 0 }
        Write-Progress -Activity '扫描游戏中' -Status $c.Name -PercentComplete $pct
        $target = Find-DlssgTarget $c.Folder
        if ($target) { Add-GameIfUnique (New-GameEntry $c.Name $target '自动扫描') }
    }
    Write-Progress -Activity '扫描游戏中' -Completed
    Write-Ok ("扫描完成，共找到 {0} 个支持 DLSS 帧生成的游戏。" -f $script:Games.Count)
}

function Invoke-ScanInstalled {
    Write-Head '扫描已安装本 Mod 的游戏'
    $candidates = Get-CandidateGameFolders
    $total = $candidates.Count
    Write-Info ("发现 {0} 个候选游戏目录，正在检查 dlssg_sm86.ini ..." -f $total)

    $i = 0
    foreach ($c in $candidates) {
        $i++
        $pct = if ($total -gt 0) { [int](($i / $total) * 100) } else { 0 }
        Write-Progress -Activity '扫描已安装' -Status $c.Name -PercentComplete $pct
        $target = Find-InstalledTarget $c.Folder
        if ($target) { Add-GameIfUnique (New-InstalledEntry $c.Name $target) }
    }
    Write-Progress -Activity '扫描已安装' -Completed
    Write-Ok ("扫描完成，共找到 {0} 个已安装 Mod 的游戏。" -f $script:Games.Count)
}

function Add-ManualGames([switch]$Installed) {
    Write-Host ''
    Write-Info '手动添加：请输入游戏目录，或渲染 EXE 的完整路径。输入空行结束。'
    while ($true) {
        $p = Read-Host '  路径'
        if ([string]::IsNullOrWhiteSpace($p)) { break }
        $p = $p.Trim('"').Trim()
        if (-not (Test-Path -LiteralPath $p)) { Write-Warn2 "路径不存在：$p"; continue }
        $item = Get-Item -LiteralPath $p
        $folder = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }

        if ($Installed) {
            $target = Find-InstalledTarget $folder
            if (-not $target) { Write-Warn2 '未在该目录找到本 Mod 的 dlssg_sm86.ini。'; continue }
            Add-GameIfUnique (New-InstalledEntry (Split-Path -Leaf $target) $target)
            Write-Ok ("已添加：{0}" -f $target)
        }
        else {
            $target = Find-DlssgTarget $folder
            if (-not $target) {
                Write-Warn2 '未在该目录找到 nvngx_dlssg.dll（可能不支持帧生成）。'
                $ans = Read-Host '  仍要强制添加此目录？(y/N)'
                if ($ans -notmatch '^[Yy]') { continue }
                $target = $folder
            }
            Add-GameIfUnique (New-GameEntry (Split-Path -Leaf $target) $target '手动添加')
            Write-Ok ("已添加：{0}" -f $target)
        }
    }
}

# ============================================================
#  列表与选择
# ============================================================
function Show-GameList([switch]$Installed) {
    if ($script:Games.Count -eq 0) { Write-Warn2 '当前列表为空。'; return }
    Write-Host ''
    if ($Installed) {
        Write-Host ('  {0,-4}{1,-32}{2,-26}{3}' -f '#', '游戏', '代理', '安装目录') -ForegroundColor White
        Write-Host ('  ' + ('-' * 72)) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $script:Games.Count; $i++) {
            $g = $script:Games[$i]
            $name = $g.Name; if ($name.Length -gt 30) { $name = $name.Substring(0, 29) + '~' }
            $proxy = if ($g.Proxies.Count -gt 0) { ($g.Proxies -join ',') } else { '(无)' }
            if ($proxy.Length -gt 24) { $proxy = $proxy.Substring(0, 23) + '~' }
            $bk = if ($g.Backups.Count -gt 0) { ' [有备份]' } else { '' }
            Write-Host ('  {0,-4}{1,-32}{2,-26}{3}{4}' -f ($i + 1), $name, $proxy, $g.TargetDir, $bk) -ForegroundColor Gray
        }
    }
    else {
        Write-Host ('  {0,-4}{1,-38}{2}' -f '#', '游戏', '安装目录') -ForegroundColor White
        Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $script:Games.Count; $i++) {
            $g = $script:Games[$i]
            $name = $g.Name; if ($name.Length -gt 36) { $name = $name.Substring(0, 35) + '~' }
            Write-Host ('  {0,-4}{1,-38}{2}' -f ($i + 1), $name, $g.TargetDir) -ForegroundColor Gray
        }
    }
}

# 返回 $null=退出, 'MANUAL'=手动添加, 或 0 基索引数组
function Read-IndexSelection([int]$count) {
    while ($true) {
        $sel = Read-Host '  选择'
        if ($null -eq $sel) { $sel = '' }
        $sel = $sel.Trim()
        if ($sel -eq '') { continue }
        if ($sel -match '^[Qq]$') { return $null }
        if ($sel -match '^[Nn]$') { return 'MANUAL' }
        if ($sel -match '^[Aa]$') { return (0..($count - 1)) }
        $indexes = @()
        $ok = $true
        foreach ($part in $sel.Split(',')) {
            $n = 0
            if (-not [int]::TryParse($part.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $count) { $ok = $false; break }
            $indexes += ($n - 1)
        }
        if (-not $ok) { Write-Warn2 '输入无效，请重新输入。'; continue }
        return ($indexes | Select-Object -Unique)
    }
}

function Select-PresetMode {
    if ($script:PresetMode) { return $script:PresetMode }
    Write-Host ''
    Write-Info '选择采样档位：'
    Write-Info '  1 = 精确档 (HardwareBilinear=0，默认，输出最准确)'
    Write-Info '  2 = 性能档 (HardwareBilinear=1，仅 SM86 生效，可能改变生成像素)'
    while ($true) {
        $a = Read-Host '  档位 (回车=精确)'
        if ([string]::IsNullOrWhiteSpace($a) -or $a -eq '1') { return 'Exact' }
        if ($a -eq '2') { return 'Performance' }
        Write-Warn2 '请输入 1 或 2。'
    }
}

# ============================================================
#  包完整性检查
# ============================================================
function Test-PackageIntegrity {
    Write-Head '包完整性检查'
    $sources = @($script:ProxyDefault)
    foreach ($n in $script:AltNames) { $sources += (Join-Path $script:AltDir $n) }

    $bad = @()
    foreach ($f in $sources) {
        $leaf = Split-Path -Leaf $f
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Bad ("缺少文件：{0}" -f $leaf); $bad += $f; continue
        }
        $len = (Get-Item -LiteralPath $f).Length
        if ($len -lt 1MB) {
            Write-Bad ("{0} 体积异常 ({1} 字节)" -f $leaf, $len); $bad += $f; continue
        }
        if (Test-ProxySignature $f) {
            Write-Ok ("{0}  签名正常 ({1:N1} MB)" -f $leaf, ($len / 1MB))
        } else {
            Write-Warn2 ("{0} 未通过项目签名核验，可能被篡改。" -f $leaf); $bad += $f
        }
    }
    if ($bad.Count -gt 0) {
        Write-Warn2 '存在未通过核验的 DLL，继续安装有风险。'
        $a = Read-Host '  仍要继续？(y/N)'
        if ($a -notmatch '^[Yy]') { return $false }
    }
    return $true
}

# ============================================================
#  安装
# ============================================================
function Get-ProxySource([string]$targetDir, [ref]$outName) {
    $src = $script:ProxyDefault
    $name = 'version.dll'
    $existing = Join-Path $targetDir $name

    if (Test-Path -LiteralPath $existing) {
        $h1 = Get-Sha256 $existing
        $h2 = Get-Sha256 $script:ProxyDefault
        if ($h1 -ne $h2) {
            Write-Warn2 ("{0} 已存在且不是本 Mod 文件（可能属于其他 Mod）。" -f $name)
            $picked = $null
            foreach ($alt in $script:AltNames) {
                $cand = Join-Path $targetDir $alt
                if (-not (Test-Path -LiteralPath $cand)) { $picked = $alt; break }
            }
            if (-not $picked) { throw 'version.dll 被占用，且所有替代入口均已被占用。' }
            $src  = Join-Path $script:AltDir $picked
            $name = $picked
            Write-Info ("改用替代入口：{0}" -f $name)
        }
    }
    $outName.Value = $name
    return $src
}

function Install-ToGame($game) {
    Write-Step ("安装到：{0}" -f $game.TargetDir)
    try {
        if (-not (Test-Path -LiteralPath $game.TargetDir)) { Write-Bad '目录不存在，跳过。'; return $false }
        if (-not (Test-SafeTargetDir $game.TargetDir)) {
            Write-Bad '目标位于系统/盘符根目录，出于安全考虑拒绝写入。'; return $false
        }
        if (Test-GameRunning $game) {
            Write-Warn2 ("检测到游戏正在运行（{0}），请先完全退出游戏。" -f $game.MainExe); return $false
        }

        $proxyName = $null
        $srcDll = Get-ProxySource $game.TargetDir ([ref]$proxyName)

        $targetDll = Join-Path $game.TargetDir $proxyName
        $targetIni = Join-Path $game.TargetDir 'dlssg_sm86.ini'
        if (Test-IsReparse $targetDll) { Write-Bad '目标 DLL 是符号链接/重解析点，拒绝写入。'; return $false }
        if (Test-IsReparse $targetIni) { Write-Bad '目标 INI 是符号链接/重解析点，拒绝写入。'; return $false }

        # 备份将被覆盖的文件
        $backupDir = Join-Path $game.TargetDir ('dlssg_sm86_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $toBackup = @($proxyName, 'dlssg_sm86.ini') | Where-Object { Test-Path -LiteralPath (Join-Path $game.TargetDir $_) }
        if ($toBackup.Count -gt 0) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            foreach ($f in $toBackup) {
                Copy-Item -LiteralPath (Join-Path $game.TargetDir $f) -Destination (Join-Path $backupDir $f) -Force
            }
            Write-Info ("已备份原文件到：{0}" -f (Split-Path -Leaf $backupDir))
        }

        # 复制代理 DLL 并校验完整性
        Copy-Item -LiteralPath $srcDll -Destination $targetDll -Force
        if ((Get-Sha256 $srcDll) -ne (Get-Sha256 $targetDll)) {
            Write-Bad '复制后的 DLL 校验失败，已保留备份，请重试。'; return $false
        }

        # 生成 INI
        $router = $script:Router
        if (-not $router) {
            do { $ans = Read-Host '  未能确定显卡架构，请选择 Router (1=SM86 RTX30系 / 2=SM75 RTX20系)' }
            while ($ans -notin @('1', '2'))
            $router = if ($ans -eq '1') { 'SM86' } else { 'SM75' }
        }
        if (-not $script:PresetMode) { $script:PresetMode = Select-PresetMode }
        $bilinear = if ($script:PresetMode -eq 'Performance') { '1' } else { '0' }

        $iniText = Get-Content -LiteralPath $script:IniSource -Raw
        $iniText = Set-IniLine $iniText 'Router' $router
        $iniText = Set-IniLine $iniText 'HardwareBilinear' $bilinear
        Set-Content -LiteralPath $targetIni -Value $iniText -Encoding ASCII

        $presetLabel = if ($bilinear -eq '1') { '性能档' } else { '精确档' }
        Write-Ok ("已安装 {0} + dlssg_sm86.ini (Router={1}, {2})" -f $proxyName, $router, $presetLabel)
        return $true
    }
    catch {
        Write-Bad $_.Exception.Message
        return $false
    }
}

# ============================================================
#  卸载
# ============================================================
function Uninstall-FromGame($entry, [bool]$restore) {
    Write-Step ("卸载：{0}" -f $entry.TargetDir)
    try {
        if (-not (Test-Path -LiteralPath $entry.TargetDir)) { Write-Bad '目录不存在，跳过。'; return $false }
        if (Test-GameRunning $entry) {
            Write-Warn2 ("检测到游戏正在运行（{0}），请先完全退出游戏。" -f $entry.MainExe); return $false
        }

        $files = @()
        foreach ($p in $entry.Proxies) { $files += $p }
        if ($entry.HasIni) { $files += 'dlssg_sm86.ini' }
        if ($files.Count -eq 0) { Write-Warn2 '未找到本 Mod 的文件，跳过。'; return $false }

        $trash = Join-Path $entry.TargetDir ('dlssg_sm86_uninstalled_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $trash -Force | Out-Null
        foreach ($f in $files) {
            $src = Join-Path $entry.TargetDir $f
            if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination (Join-Path $trash $f) -Force }
        }
        Write-Ok ("已移除：{0}  (暂存于 {1})" -f ($files -join ', '), (Split-Path -Leaf $trash))

        if ($restore -and $entry.Backups.Count -gt 0) {
            $latest = $entry.Backups[0].FullName
            Get-ChildItem -LiteralPath $latest -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $entry.TargetDir $_.Name) -Force
            }
            Write-Ok ("已从备份恢复：{0}" -f (Split-Path -Leaf $latest))
        }
        return $true
    }
    catch {
        Write-Bad $_.Exception.Message
        return $false
    }
}

function Invoke-UninstallFlow {
    if ($GamePath -and $GamePath.Count -gt 0) {
        Write-Head '使用指定路径'
        foreach ($p in $GamePath) {
            if (-not (Test-Path -LiteralPath $p)) { Write-Warn2 "路径不存在：$p"; continue }
            $item = Get-Item -LiteralPath $p
            $folder = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
            $target = Find-InstalledTarget $folder
            if ($target) { Add-GameIfUnique (New-InstalledEntry (Split-Path -Leaf $target) $target) }
        }
    } else {
        Invoke-ScanInstalled
    }

    if ($script:Games.Count -eq 0) {
        Write-Warn2 '没有找到可卸载的安装。'
        Add-ManualGames -Installed
        if ($script:Games.Count -eq 0) { return }
    }

    Write-Head '选择要卸载的游戏'
    Show-GameList -Installed
    Write-Host ''
    Write-Info '输入编号（如 1,3）、a=全部、n=手动输入路径、q=返回。'

    while ($true) {
        $sel = Read-IndexSelection $script:Games.Count
        if ($null -eq $sel) { return }
        if ($sel -is [string]) { Add-ManualGames -Installed; Show-GameList -Installed; continue }

        $restore = $false
        if (($sel | Where-Object { $script:Games[$_].Backups.Count -gt 0 }).Count -gt 0) {
            $a = Read-Host '  是否从最近的备份恢复原文件？(y/N)'
            if ($a -match '^[Yy]') { $restore = $true }
        }
        $confirm = Read-Host ('  确认卸载这 {0} 个游戏？(y/N)' -f $sel.Count)
        if ($confirm -notmatch '^[Yy]') { Write-Info '已取消。'; return }

        $okCount = 0
        Write-Host ''
        foreach ($idx in $sel) { if (Uninstall-FromGame $script:Games[$idx] $restore) { $okCount++ } }
        Write-Host ''
        Write-Ok ("卸载完成：成功 {0} / {1} 个游戏。" -f $okCount, $sel.Count)
        return
    }
}

# ============================================================
#  档位切换
# ============================================================
function Switch-PresetForGame($entry, [string]$mode) {
    Write-Step ("切换档位：{0}" -f $entry.TargetDir)
    try {
        $ini = Join-Path $entry.TargetDir 'dlssg_sm86.ini'
        if (-not (Test-Path -LiteralPath $ini)) { Write-Warn2 '未找到 dlssg_sm86.ini，跳过。'; return $false }
        if (Test-IsReparse $ini) { Write-Bad 'INI 是符号链接/重解析点，拒绝写入。'; return $false }

        $val = if ($mode -eq 'Performance') { '1' } else { '0' }
        $text = Get-Content -LiteralPath $ini -Raw
        $new  = Set-IniLine $text 'HardwareBilinear' $val
        Set-Content -LiteralPath $ini -Value $new -Encoding ASCII
        Write-Ok ("已设为 {0} (HardwareBilinear={1})" -f $mode, $val)
        return $true
    }
    catch {
        Write-Bad $_.Exception.Message
        return $false
    }
}

function Invoke-SwitchPresetFlow {
    if ($GamePath -and $GamePath.Count -gt 0) {
        Write-Head '使用指定路径'
        foreach ($p in $GamePath) {
            if (-not (Test-Path -LiteralPath $p)) { Write-Warn2 "路径不存在：$p"; continue }
            $item = Get-Item -LiteralPath $p
            $folder = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
            $target = Find-InstalledTarget $folder
            if ($target) { Add-GameIfUnique (New-InstalledEntry (Split-Path -Leaf $target) $target) }
        }
    } else {
        Invoke-ScanInstalled
    }

    if ($script:Games.Count -eq 0) {
        Write-Warn2 '没有找到已安装 Mod 的游戏。'
        Add-ManualGames -Installed
        if ($script:Games.Count -eq 0) { return }
    }

    Write-Head '选择要切换档位的游戏'
    Show-GameList -Installed
    Write-Host ''
    Write-Info '输入编号（如 1,3）、a=全部、n=手动输入路径、q=返回。'

    while ($true) {
        $sel = Read-IndexSelection $script:Games.Count
        if ($null -eq $sel) { return }
        if ($sel -is [string]) { Add-ManualGames -Installed; Show-GameList -Installed; continue }

        if (-not $script:PresetMode) { $script:PresetMode = Select-PresetMode }
        $okCount = 0
        Write-Host ''
        foreach ($idx in $sel) { if (Switch-PresetForGame $script:Games[$idx] $script:PresetMode) { $okCount++ } }
        Write-Host ''
        Write-Ok ("档位切换完成：成功 {0} / {1} 个游戏。" -f $okCount, $sel.Count)
        return
    }
}

# ============================================================
#  安装流程
# ============================================================
function Invoke-InstallFlow {
    if ($script:GpuState -in @('Unsupported', 'NativeFG')) {
        $ans = Read-Host '  当前显卡非推荐型号，仍要继续？(y/N)'
        if ($ans -notmatch '^[Yy]') { return }
    }

    if ($GamePath -and $GamePath.Count -gt 0) {
        Write-Head '使用指定路径'
        foreach ($p in $GamePath) {
            if (-not (Test-Path -LiteralPath $p)) { Write-Warn2 "路径不存在：$p"; continue }
            $item = Get-Item -LiteralPath $p
            $folder = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
            $target = Find-DlssgTarget $folder
            if (-not $target) { $target = $folder }
            Add-GameIfUnique (New-GameEntry (Split-Path -Leaf $target) $target '指定路径')
        }
    } else {
        Invoke-ScanGames
    }

    if ($script:Games.Count -eq 0) {
        Write-Warn2 '没有找到支持 DLSS 帧生成的游戏。'
        Add-ManualGames
        if ($script:Games.Count -eq 0) { return }
    }

    Write-Head '选择要安装的游戏'
    Show-GameList
    Write-Host ''
    Write-Info '输入编号（如 1,3,5）、a=全部、n=手动输入路径、q=返回。'

    while ($true) {
        $sel = Read-IndexSelection $script:Games.Count
        if ($null -eq $sel) { return }
        if ($sel -is [string]) { Add-ManualGames; Show-GameList; continue }

        if (-not $script:PresetMode) { $script:PresetMode = Select-PresetMode }

        $okCount = 0
        Write-Host ''
        foreach ($idx in $sel) { if (Install-ToGame $script:Games[$idx]) { $okCount++ } }
        Write-Host ''
        Write-Ok ("安装完成：成功 {0} / {1} 个游戏。" -f $okCount, $sel.Count)
        Write-Info '请重启游戏，在画面设置中开启 DLSS 帧生成（2X/3X/4X）。'
        return
    }
}

# ============================================================
#  定位 / 下载 Mod 文件
# ============================================================
function Find-PackageDir {
    $parents = @($script:Root)
    $parent = Split-Path -Parent $script:Root
    if ($parent) { $parents += $parent }

    $cands = @()
    foreach ($base in $parents) {
        $cands += $base
        $cands += (Join-Path $base 'dlssg_for_sm86-main')
        $cands += (Join-Path $base 'dlssg_sm86-main')
        $cands += (Join-Path $base 'mod')
        $cands += (Join-Path $base 'DLSSG')
    }
    foreach ($d in ($cands | Select-Object -Unique)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        if ((Test-Path -LiteralPath (Join-Path $d 'version.dll')) -and
            (Test-Path -LiteralPath (Join-Path $d 'dlssg_sm86.ini'))) {
            return (Resolve-Path -LiteralPath $d).Path
        }
    }
    return $null
}

function Set-RepoFromUrl([string]$url) {
    if ($url -match 'github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$') {
        $script:RepoOwner  = $matches[1]
        $script:RepoName   = $matches[2]
        $script:ProjectUrl = "https://github.com/$($script:RepoOwner)/$($script:RepoName)"
    }
}

# 读取系统（WinINET）代理，供 curl 使用；无代理返回 $null
function Get-SystemProxyUri {
    try {
        $p = [System.Net.WebRequest]::GetSystemWebProxy()
        $u = $p.GetProxy('https://github.com')
        if ($u -and $u.Host -and $u.Host -notmatch 'github\.com') { return $u.AbsoluteUri }
    } catch { }
    return $null
}

# 带硬超时的下载。优先 curl.exe（--connect-timeout/--max-time），否则回退 Invoke-WebRequest。
# 返回 @{ Ok = $true/$false; Message = '...' }
function Invoke-DownloadFile([string]$url, [string]$outFile, [int]$timeoutSec) {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue

    $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($curl) {
        $curlArgs = @('-L', '--fail', '--silent', '--show-error', '--connect-timeout', '20', '--max-time', "$timeoutSec", '-o', $outFile, $url)
        $proxy = Get-SystemProxyUri
        if ($proxy) { $curlArgs = @('-x', $proxy) + $curlArgs }
        & $curl.Source @curlArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $outFile) -and (Get-Item -LiteralPath $outFile).Length -gt 0) {
            return @{ Ok = $true; Message = 'OK' }
        }
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Message = ("curl 退出码 {0}（连接失败或超时）" -f $LASTEXITCODE) }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing -TimeoutSec $timeoutSec
        return @{ Ok = $true; Message = 'OK' }
    } catch {
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Invoke-RawDownload([string]$destDir) {
    Write-Info '改用逐文件下载（raw.githubusercontent.com）...'
    $base = "https://raw.githubusercontent.com/$($script:RepoOwner)/$($script:RepoName)/$($script:RepoBranch)"
    $files = @('version.dll', 'dlssg_sm86.ini', 'altnative\winmm.dll', 'altnative\dinput8.dll', 'altnative\winhttp.dll', 'altnative\dxgi.dll')
    foreach ($f in $files) {
        $url = "$base/$($f -replace '\\', '/')"
        $out = Join-Path $destDir $f
        $outDir = Split-Path -Parent $out
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        Write-Info ("  -> {0}" -f $f)
        $r = Invoke-DownloadFile $url $out $script:DownloadTimeoutSec
        if (-not $r.Ok) {
            Write-Warn2 ("  下载失败：{0} ({1})" -f $f, $r.Message)
            return $false
        }
    }
    return $true
}

function Invoke-GitHubDownload([string]$destDir) {
    Write-Head '从 GitHub 下载 Mod 文件'
    Write-Info ("项目地址：{0}" -f $script:ProjectUrl)
    $proxy = Get-SystemProxyUri
    if ($proxy) {
        Write-Info ("检测到系统代理：{0}" -f $proxy)
    } else {
        Write-Warn2 '未检测到系统代理；若网络受限，请先开启代理（科学上网 / Clash 等）。'
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $archiveUrl = "https://codeload.github.com/$($script:RepoOwner)/$($script:RepoName)/zip/refs/heads/$($script:RepoBranch)"
    $tmpZip = Join-Path $env:TEMP ('dlssg_pkg_' + [guid]::NewGuid().ToString('N') + '.zip')
    $tmpDir = Join-Path $env:TEMP ('dlssg_pkg_' + [guid]::NewGuid().ToString('N'))
    $ok = $false
    try {
        Write-Info ("正在下载：{0}" -f $archiveUrl)
        $r = Invoke-DownloadFile $archiveUrl $tmpZip $script:DownloadTimeoutSec
        if (-not $r.Ok) { throw ("下载失败或超时：{0}" -f $r.Message) }
        Write-Info '正在解压...'
        Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
        $inner = Get-ChildItem -LiteralPath $tmpDir -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $inner) { throw '压缩包内容为空。' }
        foreach ($item in @('version.dll', 'dlssg_sm86.ini')) {
            $src = Join-Path $inner.FullName $item
            if (-not (Test-Path -LiteralPath $src)) { throw ("压缩包中缺少 {0}" -f $item) }
            Copy-Item -LiteralPath $src -Destination (Join-Path $destDir $item) -Force
        }
        $altSrc = Join-Path $inner.FullName 'altnative'
        if (Test-Path -LiteralPath $altSrc) {
            Copy-Item -LiteralPath $altSrc -Destination (Join-Path $destDir 'altnative') -Recurse -Force
        }
        $ok = $true
    } catch {
        Write-Warn2 ("压缩包方式失败：{0}" -f $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $ok) { $ok = Invoke-RawDownload $destDir }

    if ($ok -and (Test-Path -LiteralPath (Join-Path $destDir 'version.dll')) -and
                 (Test-Path -LiteralPath (Join-Path $destDir 'dlssg_sm86.ini'))) {
        Write-Ok ("下载完成：{0}" -f $destDir)
        return $true
    }

    Write-Bad '下载失败或超时。'
    Write-Warn2 '请检查网络连接；在受限网络环境下请先开启代理（科学上网 / Clash 等）后重试。'
    Write-Info ("也可手动下载压缩包并解压到本工具目录：{0}" -f $script:ProjectUrl)
    return $false
}

function Resolve-PackageRoot {
    $found = Find-PackageDir
    if ($found) { return $found }

    Write-Warn2 '未在工具目录附近找到 version.dll / dlssg_sm86.ini。'
    Write-Info ("项目地址：{0}" -f $script:ProjectUrl)

    $dest = Join-Path $script:Root 'mod'
    if ($ListOnly) {   # 非交互模式直接尝试下载
        if (Invoke-GitHubDownload $dest) { return $dest }
        return $null
    }
    $ans = Read-Host '  是否从 GitHub 自动下载 Mod 文件？(Y/n)'
    if ($ans -match '^[Nn]') { return $null }
    if (Invoke-GitHubDownload $dest) { return $dest }
    return $null
}

# ============================================================
#  主流程
# ============================================================
function Invoke-Interactive {
    if ($script:GpuState -eq 'NoNvidia') {
        Write-Warn2 '没有 NVIDIA 显卡，本 Mod 无法工作。'
        return
    }
    while ($true) {
        Write-Head '请选择操作'
        Write-Host '  1. 安装 / 更新 Mod 到游戏'   -ForegroundColor White
        Write-Host '  2. 卸载 Mod'                 -ForegroundColor White
        Write-Host '  3. 切换采样档位 (精确 / 性能)' -ForegroundColor White
        Write-Host '  q. 退出'                      -ForegroundColor White
        $m = Read-Host '  选择'
        switch ($m.Trim()) {
            '1' { if (Test-PackageIntegrity) { Invoke-InstallFlow }; return }
            '2' { Invoke-UninstallFlow; return }
            '3' { Invoke-SwitchPresetFlow; return }
            'q' { return }
            'Q' { return }
            default { Write-Warn2 '请输入 1 / 2 / 3 / q。' }
        }
    }
}

function Invoke-Main {
    Write-Host ''
    Write-Host '  DLSSG Native 0.2.4 一键部署 / 管理工具' -ForegroundColor Cyan
    Write-Host '  (RTX 20/30 系 DLSS 帧生成)' -ForegroundColor DarkGray
    Write-Host ("  项目地址：{0}" -f $script:ProjectUrl) -ForegroundColor DarkGray

    if ($RepoUrl) { Set-RepoFromUrl $RepoUrl }

    $pkg = Resolve-PackageRoot
    if (-not $pkg) {
        Write-Bad '未找到 Mod 文件。'
        Write-Info ("请从项目地址下载压缩包，解压到本工具目录后重试：{0}" -f $script:ProjectUrl)
        return
    }
    $script:PackageRoot  = $pkg
    $script:ProxyDefault = Join-Path $pkg 'version.dll'
    $script:IniSource    = Join-Path $pkg 'dlssg_sm86.ini'
    $script:AltDir       = Join-Path $pkg 'altnative'

    Initialize-KnownProxyHashes

    if ($Uninstall) { Invoke-UninstallFlow; return }
    if ($SwitchPreset) { Invoke-SwitchPresetFlow; return }

    Show-GpuReport

    if ($ListOnly) {
        if ($script:GpuState -eq 'NoNvidia') { return }
        Invoke-ScanGames
        Show-GameList
        return
    }

    if ($script:GpuState -eq 'NoNvidia') {
        Write-Warn2 '没有 NVIDIA 显卡，本 Mod 无法工作。'
        return
    }

    if ($GamePath -and $GamePath.Count -gt 0) {
        if (Test-PackageIntegrity) { Invoke-InstallFlow }
        return
    }

    Invoke-Interactive
}

try {
    Invoke-Main
} catch {
    Write-Host ''
    Write-Bad $_.Exception.Message
}

if (-not $NoPause) {
    Write-Host ''
    Read-Host '  按回车键退出' | Out-Null
}
