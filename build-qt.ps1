#Requires -Version 5.1
<#
.SYNOPSIS
    Full pipeline on a clean Windows PC: environment -> git clone Qt -> CMake configure -> build
    Qt WebEngine (Chromium) with H.264/AAC and Qt Multimedia -> verification -> PyQt6 /
    PyQt6-WebEngine wheels -> portable bundle -> install into the project venv -> requirements.txt.

    Prepares the environment and builds Qt 6 for Windows/MSVC:
    Qt WebEngine (with proprietary codecs, i.e. H.264/AAC/.mp4) + Qt Multimedia
    + PyQt6 and PyQt6-WebEngine Python bindings built against this Qt.

.DESCRIPTION
    In a single run:
      1. Checks and, if needed, installs tools (VS 2022 Build Tools, Git, CMake,
         Ninja, Python + html5lib, Node.js, Strawberry Perl, win_flex_bison, gperf).
      2. Enters the MSVC x64 environment (like "x64 Native Tools Command Prompt").
      3. Prepares sources (clones qt5.git or initializes missing modules).
      4. (Optional) downloads FFmpeg for the Qt Multimedia FFmpeg backend.
      5. Chooses the build mode and builds:
           AddMultimedia - WebEngine with codecs is already installed -> only
                           qtshadertools (if missing) and qtmultimedia are built. Minutes.
           Full          - full build of qtwebengine + qtmultimedia. Hours.
           Auto          - choose automatically (default).
           PyQtOnly      - leave Qt as is, only rebuild PyQt6 / PyQt6-WebEngine.
      6. Builds PyQt6 and PyQt6-WebEngine wheels from source (sip-wheel) against
         $InstallDir, then makes the bundle and installs it into the project venv.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1
    (interactive: checks, questions, plan, then the whole chain)
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -Project C:\work\myapp -QtVersion 6.11.1 -Yes
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -UseFFmpeg
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -Mode Full -QtVersion 6.8.3 -Clean
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -Mode PyQtOnly -Python C:\Python312\python.exe -AddQtToPath
#>
[CmdletBinding()]
param(
    [string]$SrcDir     = 'C:\qt6src',
    [string]$BuildDir   = 'C:\qt6build',
    [string]$InstallDir = 'C:\qt6install',
    [string]$DevDir     = 'C:\dev',

    [ValidateSet('Auto', 'Full', 'AddMultimedia', 'PyQtOnly')]
    [string]$Mode = 'Auto',

    # Only needed if there are no sources in $SrcDir yet (e.g. 6.11.1).
    [string]$QtVersion = '',

    # Build the Qt Multimedia FFmpeg backend (otherwise native Windows Media Foundation).
    [switch]$UseFFmpeg,
    # Custom URL of a zip with a shared FFmpeg build (include/lib/bin inside).
    [string]$FFmpegUrl = '',

    # Number of parallel jobs. 0 = automatic (by CPU threads and RAM).
    [int]$Jobs = 0,

    # Only check the environment and show what would be done.
    [switch]$CheckOnly,
    # Do not install missing tools, only check.
    [switch]$SkipPrereqInstall,
    # Delete build folders before configuring.
    [switch]$Clean,

    # Python used for the build venv and the project venv (64-bit CPython 3.10+).
    [string]$Python = 'python',
    # Do not build PyQt6 / PyQt6-WebEngine.
    [switch]$SkipPyQt,
    # PyQt6 / PyQt6-WebEngine versions. Empty = latest with the same major.minor as Qt.
    [string]$PyQtVersion = '',
    [string]$PyQtWebEngineVersion = '',
    # Add $InstallDir\bin to the user PATH (only to use this Qt directly, not needed for the bundle).
    [switch]$AddQtToPath,

    # Project to install PyQt6 into (venv + requirements.txt). Empty = ask; '-' = none.
    [string]$Project = '',
    # Project venv (default <Project>\.venv)
    [string]$ProjectVenv = '',
    # Where to put the portable bundle (default <Project>\vendor\pyqt-bundle or $DevDir\pyqt-bundle)
    [string]$BundleDir = '',
    # Do not modify the project's requirements.txt
    [switch]$NoRequirements,
    # Proxy for downloads (git, pip, winget, Invoke-WebRequest)
    [string]$Proxy = '',
    # Ask no questions, use defaults
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # makes Invoke-WebRequest much faster in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir    = $PSScriptRoot
$ToolsDir     = Join-Path $DevDir 'tools'
$DownloadsDir = Join-Path $DevDir 'downloads'
$LogsDir      = Join-Path $DevDir 'logs'
$ModulesBuild = "$BuildDir-modules"
$ExtraPaths   = New-Object System.Collections.Generic.List[string]

# Versions of helper tools downloaded directly
$WinFlexBisonUrl = 'https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip'
$GperfUrl        = 'https://downloads.sourceforge.net/project/gnuwin32/gperf/3.0.1/gperf-3.0.1-bin.zip'

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok]  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "        $msg" }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments = @())
    Write-Host "  > $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Exe $($Arguments -join ' ')" }
}

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    $env:Path = (@($ExtraPaths) + @($machine, $user, $wingetLinks) | Where-Object { $_ }) -join ';'
    Remove-ForeignToolchains
}

# Removes MinGW/MSYS/Cygwin and C:\Strawberry\c\bin from PATH: they contain gcc, their own cmake, zstd etc.,
# which get picked up instead of the MSVC tools and break the build (e.g. -lmingw32 in .pri files).
function Remove-ForeignToolchains {
    $bad = '\\Strawberry\\c\\bin|\\msys64\\|\\msys2\\|\\mingw(32|64)?\\|\\mingw(32|64)?$|\\cygwin(64)?\\|\\ucrt64\\|\\clang64\\'
    $parts = $env:Path -split ';' | Where-Object { $_ }
    $removed = @($parts | Where-Object { $_ -match $bad })
    if ($removed.Count -gt 0) {
        $env:Path = ($parts | Where-Object { $_ -notmatch $bad }) -join ';'
        foreach ($r in $removed) { Write-Info "Removed from PATH (for this build): $r" }
    }
}

function Add-ToolPath($dir) {
    if (-not $ExtraPaths.Contains($dir)) { $ExtraPaths.Insert(0, $dir) }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

function Install-WithWinget([string]$Id, [string]$Override = '') {
    if ($SkipPrereqInstall) { throw "Not found: $Id (installation disabled by -SkipPrereqInstall)" }
    if (-not (Test-Cmd 'winget')) {
        throw "winget not found. Install 'App Installer' from the Microsoft Store or install $Id manually (see README)."
    }
    Write-Info "Installing $Id via winget..."
    $wargs = @('install', '--id', $Id, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent')
    if ($Override) { $wargs += @('--override', $Override) }
    & winget @wargs
    # -1978335189 = already installed
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget failed to install $Id (code $LASTEXITCODE)"
    }
    Update-PathFromRegistry
}

function Get-ZipTool([string]$Url, [string]$Name) {
    $dest = Join-Path $ToolsDir $Name
    if (Test-Path $dest) { return $dest }
    if ($SkipPrereqInstall) { throw "Not found: $Name (installation disabled)" }
    New-Item -ItemType Directory -Force $DownloadsDir | Out-Null
    $zip = Join-Path $DownloadsDir "$Name.zip"
    Write-Info "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing -UserAgent 'Wget'
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    return $dest
}

function Get-QtVersionFromSource {
    $conf = Join-Path $SrcDir 'qtbase\.cmake.conf'
    if (-not (Test-Path $conf)) { return $null }
    $m = Select-String -Path $conf -Pattern 'QT_REPO_MODULE_VERSION\s+"([\d\.]+)"' | Select-Object -First 1
    if ($m) { return [version]$m.Matches[0].Groups[1].Value }
    return $null
}

function Test-PyExe([string]$exe) {
    # -> [pscustomobject]@{Version; Bits; Path} or $null (also for the Microsoft Store stub)
    try {
        $out = & $exe -c "import sys, struct; print('%d.%d|%d|%s' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P') * 8, sys.executable))" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $v, $b, $pth = "$out".Trim().Split('|')
        return [pscustomobject]@{ Version = [version]$v; Bits = [int]$b; Path = $pth }
    } catch { return $null }
}

function Find-VS {
    $vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vsw)) { return $null }
    & $vsw -latest -products * -version '[17.0,18.0)' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}

function Test-Url([string]$Url) {
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -Method Head | Out-Null; return $true }
    catch {
        # any HTTP response (403/405...) means the site is reachable
        if ($_.Exception.Response) { return $true }
        return $false
    }
}

function Set-SessionProxy([string]$p) {
    $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p; $env:ALL_PROXY = $p
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($p, $true)
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
}

function Ask([string]$Question, [string]$Default) {
    if ($Yes) { Write-Host "  $Question [$Default] -> $Default"; return $Default }
    $a = Read-Host "  $Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim().Trim('"')
}

function Ask-YesNo([string]$Question, [bool]$Default) {
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    if ($Yes) { Write-Host "  $Question [$d] -> $(if ($Default) { 'y' } else { 'n' })"; return $Default }
    while ($true) {
        $a = (Read-Host "  $Question [$d]").Trim().ToLower()
        if ($a -eq '') { return $Default }
        if ($a -in 'y', 'yes', 'д', 'да') { return $true }
        if ($a -in 'n', 'no', 'н', 'нет') { return $false }
    }
}

function Get-QtState {
    $st = [pscustomobject]@{ WebEngine = $false; Multimedia = $false; Codecs = 'unknown' }
    $st.WebEngine  = Test-Path (Join-Path $InstallDir 'bin\Qt6WebEngineCore.dll')
    $st.Multimedia = Test-Path (Join-Path $InstallDir 'bin\Qt6Multimedia.dll')
    $summary = Join-Path $BuildDir 'config.summary'
    if (Test-Path $summary) {
        $m = Select-String -Path $summary -Pattern 'Proprietary Codecs\s*\.*\s*(yes|no)' | Select-Object -First 1
        if ($m) { $st.Codecs = $m.Matches[0].Groups[1].Value }
    }
    if ($st.WebEngine -and $st.Codecs -ne 'yes') {
        # look for the proprietary-codec code directly in Qt6WebEngineCore.dll
        if (Test-DllHasH264 (Join-Path $InstallDir 'bin\Qt6WebEngineCore.dll')) { $st.Codecs = 'yes' } else { $st.Codecs = 'no' }
    }
    return $st
}

function Get-FFmpegUrl([string]$Want) {
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'build-qt.ps1' }
    } catch {
        throw "Could not get the list of FFmpeg builds from GitHub ($($_.Exception.Message)). Pass -FFmpegUrl <win64 lgpl shared zip> or unpack FFmpeg into $DevDir\ffmpeg (include, lib, bin)."
    }
    $cands = foreach ($a in $rel.assets) {
        if ($a.name -match '^ffmpeg-n(\d+\.\d+).*-win64-lgpl-shared-\1\.zip$') {
            [pscustomobject]@{ Ver = [version]$Matches[1]; Name = $a.name; Url = $a.browser_download_url }
        }
    }
    $cands = @($cands)
    if (-not $cands.Count) { throw 'The latest BtbN/FFmpeg-Builds release has no win64 lgpl shared builds - pass -FFmpegUrl.' }
    $pick = $cands | Where-Object { $_.Ver -eq [version]$Want } | Select-Object -First 1
    if (-not $pick) {
        $pick = $cands | Where-Object { $_.Ver.Major -eq ([version]$Want).Major } | Sort-Object Ver -Descending | Select-Object -First 1
    }
    if (-not $pick) { $pick = $cands | Sort-Object Ver -Descending | Select-Object -First 1 }
    if ($pick.Ver -ne [version]$Want) { Write-Warn2 "FFmpeg $Want is not available from BtbN, using $($pick.Ver) ($($pick.Name))" }
    else { Write-Info "FFmpeg $($pick.Ver): $($pick.Name)" }
    return $pick.Url
}

function Show-Checks($list) {
    Write-Host ''
    foreach ($c in $list) {
        $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$c.Status]
        Write-Host ('  [{0,-4}] {1,-18} {2}' -f $c.Status, $c.Name, $c.Detail) -ForegroundColor $color
    }
    Write-Host ''
}

function Test-DllHasH264([string]$Dll) {
    # Proprietary-codec markers in Chromium (symbol names are stripped in a release build, but
    # source paths remain): the media/formats/mp4 MP4 parser and the WebRTC H.264 decoder are
    # compiled only with proprietary_codecs.
    $bytes = [IO.File]::ReadAllBytes($Dll)
    $text  = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $ok = $text.Contains('media/formats/mp4/mp4_stream_parser') -or $text.Contains('ff_h264_decoder')
    $bytes = $null; $text = $null; [GC]::Collect()
    return $ok
}

function Get-RelPath([string]$From, [string]$To) {
    $f = $From.TrimEnd('\') + '\'
    if ($To.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)) { return $To.Substring($f.Length).Replace('\', '/') }
    return $To.Replace('\', '/')
}

function Update-Requirements([string]$ReqFile, [string]$Bundle, [string]$Root) {
    $order = @{ 'pyqt6' = 0; 'pyqt6_webengine' = 1; 'pyqt6_qt6_local' = 2 }
    $wheels = @(Get-ChildItem $Bundle -Filter '*.whl' | Where-Object { $_.Name -match '^(pyqt6|pyqt6_webengine|pyqt6_qt6_local)-\d' } |
                Sort-Object { $order[($_.Name -split '-')[0]] })
    if ($wheels.Count -lt 3) { throw "$Bundle does not contain all three wheels PyQt6 / PyQt6-WebEngine / PyQt6-Qt6-Local" }
    $lines = @()
    if (Test-Path $ReqFile) {
        Copy-Item $ReqFile "$ReqFile.bak" -Force
        $lines = @(Get-Content $ReqFile)
    }
    $marker = '# --- PyQt6 + WebEngine (H.264/AAC), local wheels - managed by build-qt.ps1 ---'
    # Drop PyQt6/PyQt6-Qt6/PyQt6-WebEngine(-Qt6)/PyQt6-sip by name and old references to our wheels
    $namePat  = '^\s*pyqt6([-_](qt6([-_]local)?|webengine([-_]qt6)?|sip))?\s*([=<>!~;\[@#]|$)'
    $wheelPat = '(^|[\\/\s])pyqt6(_webengine|_qt6_local)?-[^\\/\s]*\.whl'
    $removed = @($lines | Where-Object { $_ -match $namePat -or $_ -match $wheelPat })
    $keep = @($lines | Where-Object { $_ -notmatch $namePat -and $_ -notmatch $wheelPat -and $_ -ne $marker })
    while ($keep.Count -and [string]::IsNullOrWhiteSpace($keep[-1])) { $keep = @($keep[0..($keep.Count - 2)]) }
    $block = @('', $marker)
    foreach ($w in $wheels) { $block += (Get-RelPath $Root $w.FullName) }
    $block += 'PyQt6-sip>=13.13,<14'
    [IO.File]::WriteAllLines($ReqFile, [string[]]($keep + $block), (New-Object System.Text.UTF8Encoding($false)))
    foreach ($r in $removed) {
        if ($r -notmatch $wheelPat -and $r.Trim() -ne 'PyQt6-sip>=13.13,<14') { Write-Info "Removed from requirements: $r" }
    }
    Write-Ok "requirements.txt updated: $ReqFile$(if (Test-Path "$ReqFile.bak") { ' (backup: requirements.txt.bak)' })"
}

# ---------------------------------------------------------------------------
# 0. Log
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force $DevDir, $ToolsDir, $DownloadsDir, $LogsDir | Out-Null
$LogFile = Join-Path $LogsDir ("build-qt-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    # -----------------------------------------------------------------------
    # 0. Preflight checks and questions (nothing is changed before confirmation)
    # -----------------------------------------------------------------------
    Write-Step 'Preflight'
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
        $checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    }
    if ($Proxy) { Set-SessionProxy $Proxy }
    Update-PathFromRegistry
    $fatal = $false

    # Windows
    $os = Get-CimInstance Win32_OperatingSystem
    $osBuild = [int]$os.BuildNumber
    if (-not [Environment]::Is64BitOperatingSystem) { Add-Check 'Windows' 'FAIL' "$($os.Caption): 64-bit Windows is required"; $fatal = $true }
    elseif ($osBuild -lt 17763) { Add-Check 'Windows' 'FAIL' "build ${osBuild}: Windows 10 1809+ or 11 is required (update Windows manually)"; $fatal = $true }
    else { Add-Check 'Windows' 'OK' "$($os.Caption), build $osBuild" }

    # Toolkit files next to the script
    if (-not $SkipPyQt) {
        $kit = @('make-bundle.py', 'bundle-files\install.ps1', 'bundle-files\install.cmd', 'bundle-files\check.py', 'bundle-files\README.md')
        $kitMissing = @($kit | Where-Object { -not (Test-Path (Join-Path $ScriptDir $_)) })
        if ($kitMissing.Count) { Add-Check 'Toolkit files' 'FAIL' "missing next to the script: $($kitMissing -join ', ') - copy the whole folder"; $fatal = $true }
        else { Add-Check 'Toolkit files' 'OK' $ScriptDir }
        Get-ChildItem $ScriptDir -Recurse -File -Include *.ps1, *.py, *.cmd -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    }

    # What is already there
    $haveSrc = Test-Path (Join-Path $SrcDir 'qtbase\.cmake.conf')
    $qtState = Get-QtState
    $srcVer  = Get-QtVersionFromSource
    $predMode = $Mode
    if ($predMode -eq 'Auto') {
        if ($qtState.WebEngine -and $qtState.Codecs -eq 'yes') {
            if ($qtState.Multimedia) { $predMode = 'PyQtOnly' } else { $predMode = 'AddMultimedia' }
        } else { $predMode = 'Full' }
    }
    Add-Check 'Qt sources' $(if ($haveSrc) { 'OK' } else { 'INFO' }) $(if ($haveSrc) { "$SrcDir (Qt $srcVer)" } else { "none - git clone into $SrcDir" })
    Add-Check 'Qt WebEngine' $(if ($qtState.WebEngine) { 'OK' } else { 'INFO' }) $(if ($qtState.WebEngine) { "installed, H.264/AAC codecs: $($qtState.Codecs)" } else { 'not installed - will be built' })
    Add-Check 'Qt Multimedia' $(if ($qtState.Multimedia) { 'OK' } else { 'INFO' }) $(if ($qtState.Multimedia) { 'installed' } else { 'will be built' })
    Add-Check 'Build mode' 'INFO' $predMode

    # Resources
    $drive = (Split-Path -Qualifier $BuildDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
    $needGB = if ($predMode -eq 'Full') { 100 } else { 15 }
    $minGB  = if ($predMode -eq 'Full') { 60 } else { 8 }
    if ($freeGB -lt $minGB) { Add-Check "Disk ${drive}:" 'FAIL' "$freeGB GB free, ~$needGB GB needed - free up space"; $fatal = $true }
    elseif ($freeGB -lt $needGB) { Add-Check "Disk ${drive}:" 'WARN' "$freeGB GB free, ~$needGB GB recommended" }
    else { Add-Check "Disk ${drive}:" 'OK' "$freeGB GB free" }
    $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($predMode -eq 'Full' -and $ramGB -lt 8) { Add-Check 'Memory' 'FAIL' "$ramGB GB RAM - building Chromium needs at least 8, 16-32 recommended"; $fatal = $true }
    elseif ($predMode -eq 'Full' -and $ramGB -lt 16) { Add-Check 'Memory' 'WARN' "$ramGB GB RAM - the build will be slow, linking may fail" }
    else { Add-Check 'Memory' 'OK' "$ramGB GB RAM, $([Environment]::ProcessorCount) CPU threads" }

    # Long paths (can only be changed with admin rights)
    $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPaths -eq 1) { Add-Check 'Long paths' 'OK' 'enabled' } else { Add-Check 'Long paths' 'WARN' 'disabled - admin rights are needed to enable' }

    # Tools
    $toolIds = [ordered]@{ git = 'Git.Git'; cmake = 'Kitware.CMake'; ninja = 'Ninja-build.Ninja'; node = 'OpenJS.NodeJS.LTS'; perl = 'StrawberryPerl.StrawberryPerl' }
    $toInstall = @()
    foreach ($t in $toolIds.Keys) { if (-not (Test-Cmd $t)) { $toInstall += $t } }
    $pyInfo = Test-PyExe $Python
    $pyOk = $pyInfo -and $pyInfo.Version -ge [version]'3.10' -and $pyInfo.Bits -eq 64
    if (-not $pyOk) {
        if ($Python -ne 'python') { Add-Check 'Python' 'FAIL' "-Python ${Python}: 64-bit Python 3.10+ is required"; $fatal = $true }
        else { $toInstall += 'python' }
    }
    $vsFound = Find-VS
    if (-not $vsFound) { $toInstall += 'Visual Studio 2022 Build Tools (C++)' }
    if ($toInstall.Count) { Add-Check 'Tools' 'INFO' "will be installed: $($toInstall -join ', ')" }
    else { Add-Check 'Tools' 'OK' 'git, cmake, ninja, node, perl, python, VS 2022' }
    if ($pyOk) { Add-Check 'Python' 'OK' "$($pyInfo.Version) $($pyInfo.Path)" }
    if ($pyOk -and $pyInfo.Path -like '*\WindowsApps\*') { Add-Check 'Python (Store)' 'WARN' 'Microsoft Store Python: works, but python.org Python is more reliable' }
    $haveWinget = Test-Cmd 'winget'
    if ($toInstall.Count -and -not $haveWinget) {
        Add-Check 'winget' 'FAIL' 'no winget, but tools must be installed: install "App Installer" from the Microsoft Store'; $fatal = $true
    } elseif ($haveWinget) { Add-Check 'winget' 'OK' 'present' }

    # Network
    $urls = [ordered]@{}
    if ($predMode -ne 'PyQtOnly') { $urls['code.qt.io'] = 'https://code.qt.io/' }
    $urls['github.com'] = 'https://github.com/'
    if (-not $SkipPyQt) { $urls['pypi.org'] = 'https://pypi.org/simple/pyqt6/' }
    $netBad = @()
    foreach ($k in $urls.Keys) { if (-not (Test-Url $urls[$k])) { $netBad += $k } }
    if ($netBad.Count -and -not $Proxy -and -not $Yes) {
        Show-Checks $checks
        Write-Host "  No access to: $($netBad -join ', ')" -ForegroundColor Yellow
        $px = Read-Host '  Proxy URL (e.g. http://proxy:3128), empty if there is no proxy'
        if ($px) {
            $Proxy = $px.Trim(); Set-SessionProxy $Proxy
            $netBad = @($netBad | Where-Object { -not (Test-Url $urls[$_]) })
        }
    }
    if ($netBad.Count) { Add-Check 'Network' 'FAIL' "no access to: $($netBad -join ', ') - connect to the internet or pass -Proxy"; $fatal = $true }
    else {
        $netDetail = (@($urls.Keys) -join ', ') + $(if ($Proxy) { " (proxy $Proxy)" } else { '' })
        Add-Check 'Network' 'OK' $netDetail
    }

    # Media Foundation (without it QtMultimedia cannot play video; installed manually / with admin rights)
    if (Test-Path "$env:windir\System32\mfplat.dll") { Add-Check 'Media Foundation' 'OK' 'present' }
    else { Add-Check 'Media Foundation' 'WARN' 'missing (Windows N): install "Media Feature Pack", otherwise the video check fails' }

    Show-Checks $checks
    if ($fatal) { throw 'There are FAIL items - fix them and run the script again.' }
    if ($CheckOnly) { Write-Step 'Check finished (-CheckOnly), nothing was changed'; Stop-Transcript | Out-Null; return }

    # ---------------- questions
    Write-Step 'Questions'
    if ($predMode -ne 'PyQtOnly' -and -not $haveSrc -and -not $QtVersion) {
        $QtVersion = Ask 'Qt version for git clone (tag vX.Y.Z on code.qt.io)' '6.11.1'
    }
    if (-not $Project) {
        $Project = Ask 'Project folder to install PyQt6 into (venv + requirements.txt); "-" = none' '-'
    }
    if ($Project -eq '-') { $Project = '' }
    if ($Project) {
        $Project = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Project)
        if (-not (Test-Path $Project)) {
            if (-not (Ask-YesNo "Folder $Project does not exist. Create it?" $true)) { throw 'The project folder does not exist.' }
        }
        if (-not $ProjectVenv) { $ProjectVenv = Ask 'Project venv' (Join-Path $Project '.venv') }
        if (-not $BundleDir) { $BundleDir = Ask 'Where to put the wheel bundle (for other PCs and requirements.txt)' (Join-Path $Project 'vendor\pyqt-bundle') }
        $reqFile = Join-Path $Project 'requirements.txt'
        $doReq = $false
        if (-not $NoRequirements) {
            $q = if (Test-Path $reqFile) { 'Update requirements.txt (PyQt6 by name is replaced with paths to the wheels, .bak backup)?' } else { 'Create requirements.txt with paths to the wheels?' }
            $doReq = Ask-YesNo $q $true
        }
    } else {
        if (-not $BundleDir) { $BundleDir = Join-Path $DevDir 'pyqt-bundle' }
    }
    $BundleDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BundleDir)
    if ($ProjectVenv) { $ProjectVenv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectVenv) }

    if ($predMode -in 'Full', 'AddMultimedia' -and -not $UseFFmpeg -and -not $Yes) {
        $UseFFmpeg = Ask-YesNo 'Qt Multimedia backend FFmpeg (recommended; Windows Media Foundation is deprecated since Qt 6.10)? n = Media Foundation' $true
    }

    $doLongPaths = $false; $doDefender = $false
    if ($longPaths -ne 1 -and $predMode -eq 'Full') {
        $doLongPaths = Ask-YesNo 'Enable Windows long paths (needed for Chromium; UAC prompt)?' $true
    }
    if ($predMode -eq 'Full') {
        $doDefender = Ask-YesNo "Add $SrcDir, $BuildDir, $InstallDir to Defender exclusions (makes the build several times faster; UAC prompt)?" $false
    }
    if ($toInstall -contains 'Visual Studio 2022 Build Tools (C++)') {
        if (-not (Ask-YesNo 'Install Visual Studio 2022 Build Tools with C++ (~10 GB, UAC prompt)?' $true)) {
            throw 'The build is impossible without MSVC. Install VS 2022 with "Desktop development with C++" and run again.'
        }
    }

    # ---------------- plan
    Write-Step 'Plan'
    if ($toInstall.Count) { Write-Info "1. Install: $($toInstall -join ', ')" } else { Write-Info '1. All tools are present' }
    $admList = @()
    if ($doLongPaths) { $admList += 'long paths' }
    if ($doDefender)  { $admList += 'Defender exclusions' }
    if ($admList.Count) { Write-Info "   With admin rights (UAC): $($admList -join ', ')" }
    switch ($predMode) {
        'Full'          { if ($haveSrc) { Write-Info "2. Qt $srcVer sources found in $SrcDir - fetch missing submodules (including Chromium)" }
                          else { Write-Info "2. git clone qt5.git v$QtVersion + submodules (qtwebengine with Chromium ~ 10+ GB)" }
                          Write-Info "3. CMake configure: -webengine-proprietary-codecs, qtwebengine+qtmultimedia, backend $(if ($UseFFmpeg) { 'FFmpeg' } else { 'Media Foundation' })"
                          Write-Info "4. Build and install into $InstallDir (several hours)" }
        'AddMultimedia' { Write-Info "2-4. WebEngine with codecs is already there - build qtmultimedia only (minutes)" }
        'PyQtOnly'      { Write-Info "2-4. Qt with WebEngine (codecs) and Multimedia is already there - skipping the Qt build" }
    }
    Write-Info '5. Component check: WebEngine, QtWebEngineProcess, Multimedia, plugins, H.264 in Qt6WebEngineCore.dll'
    if (-not $SkipPyQt) {
        Write-Info "6. PyQt6 + PyQt6-WebEngine wheels from source (sip-wheel) -> $DevDir\wheels (30-60 min)"
        Write-Info "7. Bundle (Qt runtime wheel + installer) -> $BundleDir"
        if ($Project) {
            Write-Info "8. Install into the project venv $ProjectVenv and check .mp4"
            if ($doReq) { Write-Info "9. requirements.txt: $reqFile" }
        }
    }
    $eta = switch ($predMode) { 'Full' { '4-10 h' } 'AddMultimedia' { '~1-1.5 h' } default { '~40-70 min' } }
    Write-Info "Estimated time: $eta. Log: $LogFile"
    Write-Host ''
    if (-not (Ask-YesNo 'Start?' $true)) { Write-Host 'Cancelled, nothing was changed.'; Stop-Transcript | Out-Null; return }

    if ($Mode -eq 'Auto') { $Mode = $predMode }

    # Admin actions - one UAC prompt
    $adm = @()
    if ($doLongPaths) { $adm += "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force | Out-Null" }
    if ($doDefender)  { $adm += "Add-MpPreference -ExclusionPath '$SrcDir','$BuildDir','$InstallDir','$DevDir'" }
    if ($adm.Count) {
        Write-Step 'Settings with admin rights'
        try {
            $pr = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-Command', ("try { " + ($adm -join '; ') + "; exit 0 } catch { exit 1 }")
            if ($pr.ExitCode -eq 0) { Write-Ok 'Applied' } else { Write-Warn2 'Could not apply (see README) - continuing' }
        } catch { Write-Warn2 'UAC declined - continuing without these settings' }
    }

    # -----------------------------------------------------------------------
    # 1. System checks
    # -----------------------------------------------------------------------
    Write-Step 'System checks'

    $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPaths -eq 1) { Write-Ok 'Long paths enabled' }
    else { Write-Warn2 'LongPathsEnabled is off. It is recommended to enable it (see README), otherwise Chromium may fail.' }

    $drive = (Split-Path -Qualifier $BuildDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
    if ($freeGB -lt 100) { Write-Warn2 "${drive}: $freeGB GB free. A full WebEngine build needs ~100 GB." }
    else { Write-Ok "${drive}: $freeGB GB free" }

    $cores = [Environment]::ProcessorCount
    $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($Jobs -le 0) { $Jobs = [math]::Max(1, [math]::Min($cores, [math]::Floor($ramGB / 2))) }
    Write-Ok "CPU: $cores threads, RAM: $ramGB GB -> parallel jobs: $Jobs"
    if ($ramGB -lt 16) { Write-Warn2 'Less than 16 GB RAM: the WebEngine build will be very slow or fail at linking.' }

    # -----------------------------------------------------------------------
    # 2. Tools
    # -----------------------------------------------------------------------
    Write-Step 'Build tools'
    Update-PathFromRegistry

    $simpleTools = @(
        @{ Cmd = 'git';   Id = 'Git.Git' },
        @{ Cmd = 'cmake'; Id = 'Kitware.CMake' },
        @{ Cmd = 'ninja'; Id = 'Ninja-build.Ninja' },
        @{ Cmd = 'node';  Id = 'OpenJS.NodeJS.LTS' },
        @{ Cmd = 'perl';  Id = 'StrawberryPerl.StrawberryPerl' }
    )
    foreach ($t in $simpleTools) {
        if (-not (Test-Cmd $t.Cmd)) { Install-WithWinget $t.Id }
        if (-not (Test-Cmd $t.Cmd)) { throw "$($t.Cmd) not found in PATH after installation. Restart PowerShell and the script." }
        Write-Ok "$($t.Cmd): $((Get-Command $t.Cmd).Source)"
    }

    # Python (filter out the Microsoft Store stub)
    function Test-Python { try { return ((& $Python -c "import sys; print(sys.version_info[0])" 2>$null) -eq '3') } catch { return $false } }
    if (-not (Test-Python)) {
        if ($Python -ne 'python') { throw "The given Python does not run: $Python" }
        Install-WithWinget 'Python.Python.3.12'
        if (-not (Test-Python)) { throw 'Python 3 does not run. Turn off the python aliases in "Settings > Apps > App execution aliases" (see README).' }
    }
    $pyI = Test-PyExe $Python
    if (-not $pyI -or $pyI.Bits -ne 64 -or $pyI.Version -lt [version]'3.10') {
        throw "64-bit Python 3.10+ is required (PyQt6 wheels are cp310-abi3), but $Python is $(if ($pyI) { "$($pyI.Version), $($pyI.Bits)-bit" } else { 'not runnable' })."
    }
    $Python = (& $Python -c "import sys; print(sys.executable)")
    Write-Ok "python: $(& $Python --version) ($Python)"
    if ($Python -like '*\WindowsApps\*') {
        Write-Warn2 'This is Microsoft Store Python. It works, but python.org Python is more reliable for building (see README).'
    }

    # All build packages (html5lib, sip, PyQt-builder) go into a separate venv,
    # so your main Python is left untouched.
    $BuildVenv = Join-Path $DevDir 'venv-build'
    $BuildPy   = Join-Path $BuildVenv 'Scripts\python.exe'
    if (-not $CheckOnly) {
        if (Test-Path $BuildPy) {
            $venvVer = & $BuildPy -c "import sys; print('%d.%d' % sys.version_info[:2])"
            $mainVer = & $Python  -c "import sys; print('%d.%d' % sys.version_info[:2])"
            if ($venvVer -ne $mainVer) { Remove-Item -Recurse -Force $BuildVenv }
        }
        if (-not (Test-Path $BuildPy)) {
            Write-Info "Creating build venv: $BuildVenv"
            Invoke-Native $Python @('-m', 'venv', $BuildVenv)
        }
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'pip', 'html5lib')
        # Qt configure takes python from PATH - put the venv first
        Add-ToolPath (Join-Path $BuildVenv 'Scripts')
        Write-Ok "Build venv: $BuildVenv"
    }

    # Node.js >= 14 (18+ is better for recent Qt)
    $nodeVer = [version]((& node --version).TrimStart('v'))
    if ($nodeVer.Major -lt 14) { throw "Node.js $nodeVer is too old, >= 14 is required (LTS recommended)." }

    # win_flex_bison
    if (-not ((Test-Cmd 'win_bison') -or (Test-Cmd 'bison'))) {
        Add-ToolPath (Get-ZipTool $WinFlexBisonUrl 'winflexbison')
    }
    Write-Ok "bison/flex: $((Get-Command win_bison, bison -ErrorAction SilentlyContinue | Select-Object -First 1).Source)"

    # gperf
    if (-not (Test-Cmd 'gperf')) {
        Add-ToolPath (Join-Path (Get-ZipTool $GperfUrl 'gperf') 'bin')
    }
    Write-Ok "gperf: $((Get-Command gperf).Source)"

    # Visual Studio 2022 (MSVC x64 + Windows SDK)
    $vsPath = Find-VS
    if (-not $vsPath) {
        Write-Warn2 'Visual Studio 2022 with MSVC not found - installing Build Tools (takes a while, ~10 GB).'
        Install-WithWinget 'Microsoft.VisualStudio.2022.BuildTools' `
            '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended'
        $vsPath = Find-VS
        if (-not $vsPath) { throw 'Visual Studio 2022 not found after installation. Install it manually (see README).' }
    }
    Write-Ok "Visual Studio: $vsPath"

    git config --global core.longpaths true | Out-Null

    # -----------------------------------------------------------------------
    # 3. MSVC x64 environment
    # -----------------------------------------------------------------------
    Write-Step 'MSVC x64 environment'
    Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    foreach ($p in $ExtraPaths) { if (($env:Path -split ';') -notcontains $p) { $env:Path = "$p;$env:Path" } }
    Remove-ForeignToolchains
    foreach ($t in 'cmake', 'ninja', 'perl', 'python') {
        $src = (Get-Command $t -ErrorAction SilentlyContinue).Source
        if (-not $src) { throw "$t not found in PATH after removing MinGW/MSYS." }
        Write-Ok "${t}: $src"
    }
    # Keep CMake from finding libraries in MSYS2/Strawberry (e.g. zstd from C:\msys64)
    $env:CMAKE_IGNORE_PREFIX_PATH = 'C:/msys64/ucrt64;C:/msys64/mingw64;C:/msys64/clang64;C:/msys64/usr;C:/Strawberry/c'
    if (-not (Test-Cmd 'cl')) { throw 'cl.exe not found after entering the VS environment.' }
    Write-Ok "cl.exe: $((Get-Command cl).Source)"
    if (-not $env:WindowsSdkDir) { Write-Warn2 'Windows SDK not found in the environment - add it in the VS installer.' }
    else { Write-Ok "Windows SDK: $env:WindowsSDKVersion" }

    # -----------------------------------------------------------------------
    # 4. Sources
    # -----------------------------------------------------------------------
    # Full: everything for WebEngine; AddMultimedia: only what is built on top of the installed Qt
    if ($Mode -eq 'AddMultimedia') { $needModules = @('qtbase', 'qtshadertools', 'qtmultimedia') }
    else {
        $needModules = @('qtbase', 'qtshadertools', 'qtdeclarative', 'qtsvg', 'qtwebchannel',
                         'qtpositioning', 'qttools', 'qtwebengine', 'qtmultimedia')
    }
    $needChromium = ($Mode -eq 'Full')

    if ($Mode -eq 'PyQtOnly') { }
    elseif (-not (Test-Path (Join-Path $SrcDir 'qtbase\.cmake.conf'))) {
        Write-Step 'Qt sources'
        if (-not $QtVersion) { throw "No sources in $SrcDir. Pass the version: -QtVersion 6.11.1" }
        if ($CheckOnly) { Write-Warn2 "qt5.git v$QtVersion would be cloned into $SrcDir" }
        else {
            if (-not (Test-Path (Join-Path $SrcDir '.git'))) {
                Invoke-Native git @('clone', '--branch', "v$QtVersion", 'https://code.qt.io/qt/qt5.git', $SrcDir)
            }
            Invoke-Native git (@('-C', $SrcDir, 'submodule', 'update', '--init') + $needModules)
            if ($needChromium) {
                Write-Info 'Fetching Chromium (qtwebengine/src/3rdparty) - several GB, this may take a long time...'
                Invoke-Native git @('-C', (Join-Path $SrcDir 'qtwebengine'), 'submodule', 'update', '--init', '--recursive')
            }
        }
    }
    else {
        Write-Step 'Qt sources'
        # Initialize only missing modules, leave already fetched ones alone
        $missing = @($needModules | Where-Object { -not (Test-Path (Join-Path $SrcDir "$_\CMakeLists.txt")) })
        if ($missing.Count -gt 0) {
            Write-Info "Missing modules: $($missing -join ', ')"
            if (-not $CheckOnly) {
                Invoke-Native git (@('-C', $SrcDir, 'submodule', 'update', '--init') + $missing)
                if ($missing -contains 'qtwebengine') {
                    Invoke-Native git @('-C', (Join-Path $SrcDir 'qtwebengine'), 'submodule', 'update', '--init', '--recursive')
                }
            }
        }
        $chromium = Join-Path $SrcDir 'qtwebengine\src\3rdparty\chromium'
        if ($needChromium -and -not (Test-Path $chromium) -and -not $CheckOnly) {
            Invoke-Native git @('-C', (Join-Path $SrcDir 'qtwebengine'), 'submodule', 'update', '--init', '--recursive')
        }
    }
    $qtVer = Get-QtVersionFromSource
    if ($qtVer) { Write-Ok "Qt version in sources: $qtVer" }
    if ($Mode -ne 'PyQtOnly') {
        $srcMiss = @($needModules | Where-Object { -not (Test-Path (Join-Path $SrcDir "$_\CMakeLists.txt")) })
        if ($needChromium -and -not (Test-Path (Join-Path $SrcDir 'qtwebengine\src\3rdparty\chromium'))) { $srcMiss += 'qtwebengine\src\3rdparty (Chromium)' }
        if ($srcMiss.Count) { throw "Sources still missing after git: $($srcMiss -join ', ')" }
        Write-Ok "Sources present: $($needModules -join ', ')$(if ($needChromium) { ' + Chromium' })"
    }

    # -----------------------------------------------------------------------
    # 5. FFmpeg (optional)
    # -----------------------------------------------------------------------
    $ffmpegDir = Join-Path $DevDir 'ffmpeg'
    if ($UseFFmpeg -and $Mode -ne 'PyQtOnly') {
        Write-Step 'FFmpeg'
        if (-not (Test-Path (Join-Path $ffmpegDir 'include\libavcodec'))) {
            if (-not $FFmpegUrl) {
                # Qt 6.8+ is built against FFmpeg 7.1, Qt 6.5-6.7 against 6.1. BtbN file names change,
                # so take the current list from the GitHub API.
                if ($qtVer -and $qtVer -lt [version]'6.8') { $ff = '6.1' } else { $ff = '7.1' }
                $FFmpegUrl = Get-FFmpegUrl $ff
            }
            if ($CheckOnly) { Write-Warn2 "Would download $FFmpegUrl" }
            else {
                $zip = Join-Path $DownloadsDir 'ffmpeg.zip'
                $tmp = Join-Path $DownloadsDir 'ffmpeg-extract'
                Write-Info "Downloading $FFmpegUrl"
                Invoke-WebRequest -Uri $FFmpegUrl -OutFile $zip -UseBasicParsing
                if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
                Expand-Archive -Path $zip -DestinationPath $tmp -Force
                $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
                if (Test-Path $ffmpegDir) { Remove-Item -Recurse -Force $ffmpegDir }
                Move-Item $inner.FullName $ffmpegDir
                Remove-Item -Recurse -Force $tmp
            }
        }
        if (Test-Path (Join-Path $ffmpegDir 'include\libavcodec')) { Write-Ok "FFmpeg: $ffmpegDir" }
        $env:FFMPEG_DIR = $ffmpegDir
    }
    if ($UseFFmpeg) { $mmCmakeArgs = @("-DFFMPEG_DIR=$ffmpegDir") }
    else            { $mmCmakeArgs = @('-DQT_FEATURE_ffmpeg=OFF') }

    # -----------------------------------------------------------------------
    # 6. Build mode
    # -----------------------------------------------------------------------
    Write-Step 'Build mode'
    $webengineInstalled = $qtState.WebEngine
    $codecs = $qtState.Codecs
    Write-Info "WebEngine installed in ${InstallDir}: $webengineInstalled"
    Write-Info "Proprietary codecs in the existing build: $codecs"

    if ($Mode -eq 'Auto') {
        if ($webengineInstalled -and $codecs -eq 'yes') { $Mode = 'AddMultimedia' } else { $Mode = 'Full' }
    }
    if ($Mode -eq 'Full' -and $codecs -eq 'yes') {
        Write-Warn2 'WebEngine is already built with codecs - a full rebuild is not necessary (-Mode AddMultimedia is enough).'
    }
    if ($Mode -in @('AddMultimedia', 'PyQtOnly') -and -not $webengineInstalled) {
        throw "Mode $Mode requires an installed Qt with WebEngine in $InstallDir."
    }
    if ($SkipPyQt) { Write-Info 'PyQt6: skipped (-SkipPyQt)' }
    else           { Write-Info "PyQt6 / PyQt6-WebEngine: will be built with $Python" }
    Write-Ok "Mode: $Mode"
    if ($Mode -eq 'Full') { Write-Warn2 'A full WebEngine build takes several hours.' }


    $env:NINJAJOBS = "-j$Jobs"   # limit for Chromium's internal ninja build

    # -----------------------------------------------------------------------
    # 7. Build
    # -----------------------------------------------------------------------
    function Build-QtModule([string]$Name, [string[]]$CmakeArgs = @()) {
        Write-Step "Building module $Name"
        $bdir = Join-Path $ModulesBuild $Name
        if ($Clean -and (Test-Path $bdir)) { Remove-Item -Recurse -Force $bdir }
        New-Item -ItemType Directory -Force $bdir | Out-Null
        Remove-Item (Join-Path $bdir 'CMakeCache.txt') -ErrorAction SilentlyContinue
        Push-Location $bdir
        try {
            $cfg = @((Join-Path $SrcDir $Name))
            if ($CmakeArgs.Count -gt 0) { $cfg += '--'; $cfg += $CmakeArgs }
            Invoke-Native (Join-Path $InstallDir 'bin\qt-configure-module.bat') $cfg
            Invoke-Native cmake @('--build', '.', '--parallel', "$Jobs")
            Invoke-Native cmake @('--install', '.')
        }
        finally { Pop-Location }
    }

    if ($Mode -eq 'PyQtOnly') {
        Write-Step 'Qt build skipped (-Mode PyQtOnly)'
    }
    elseif ($Mode -eq 'AddMultimedia') {
        if (-not (Test-Path (Join-Path $InstallDir 'bin\qsb.exe'))) { Build-QtModule 'qtshadertools' }
        else { Write-Ok 'qtshadertools already installed (qsb.exe found)' }
        Build-QtModule 'qtmultimedia' $mmCmakeArgs
    }
    else {
        Write-Step 'Full build: qtwebengine + qtmultimedia'
        if ($Clean -and (Test-Path $BuildDir)) { Remove-Item -Recurse -Force $BuildDir }
        New-Item -ItemType Directory -Force $BuildDir | Out-Null
        Remove-Item (Join-Path $BuildDir 'CMakeCache.txt') -ErrorAction SilentlyContinue
        Push-Location $BuildDir
        try {
            $cfg = @(
                '-prefix', $InstallDir,
                '-release',
                '-submodules', 'qtwebengine,qtmultimedia,qtsvg,qttools',
                '-webengine-proprietary-codecs',
                '-nomake', 'examples',
                '-nomake', 'tests',
                '--'
            ) + $mmCmakeArgs
            Invoke-Native (Join-Path $SrcDir 'configure.bat') $cfg

            $sumText = Get-Content (Join-Path $BuildDir 'config.summary') -Raw
            if ($sumText -notmatch 'Proprietary Codecs\s*\.*\s*yes') {
                throw 'Proprietary codecs were not enabled - see config.summary.'
            }
            Invoke-Native cmake @('--build', '.', '--parallel', "$Jobs")
            Invoke-Native cmake @('--install', '.')
        }
        finally { Pop-Location }
    }

    # FFmpeg DLLs next to Qt, so applications start and windeployqt picks them up
    if ($UseFFmpeg -and (Test-Path (Join-Path $ffmpegDir 'bin'))) {
        Copy-Item (Join-Path $ffmpegDir 'bin\*.dll') (Join-Path $InstallDir 'bin') -Force
        Write-Ok "FFmpeg DLLs copied to $InstallDir\bin"
    }

    # -----------------------------------------------------------------------
    # 8. Result check
    # -----------------------------------------------------------------------
    Write-Step 'Result check'
    $expect = @('bin\Qt6WebEngineCore.dll', 'bin\Qt6WebEngineWidgets.dll', 'bin\QtWebEngineProcess.exe',
                'bin\Qt6Multimedia.dll', 'bin\Qt6MultimediaWidgets.dll')
    $allOk = $true
    foreach ($f in $expect) {
        if (Test-Path (Join-Path $InstallDir $f)) { Write-Ok $f } else { Write-Warn2 "Missing: $f"; $allOk = $false }
    }
    $plugins = Get-ChildItem (Join-Path $InstallDir 'plugins\multimedia') -Filter *.dll -ErrorAction SilentlyContinue
    if ($plugins) { $plugins | ForEach-Object { Write-Ok "plugins\multimedia\$($_.Name)" } }
    else { Write-Warn2 'No plugins found in plugins\multimedia'; $allOk = $false }
    foreach ($f in 'plugins\platforms\qwindows.dll', 'resources\qtwebengine_resources.pak', 'resources\icudtl.dat', 'translations\qtwebengine_locales\en-US.pak') {
        if (Test-Path (Join-Path $InstallDir $f)) { Write-Ok $f } else { Write-Warn2 "Missing: $f"; $allOk = $false }
    }
    $weDll = Join-Path $InstallDir 'bin\Qt6WebEngineCore.dll'
    if ((Test-Path $weDll) -and (Test-DllHasH264 $weDll)) { Write-Ok 'Qt6WebEngineCore.dll contains proprietary codecs (H.264/AAC)' }
    else { Write-Warn2 'Qt6WebEngineCore.dll has no H.264 - WebEngine was built without proprietary codecs'; $allOk = $false }
    if (-not $allOk) { throw "Qt components are missing in $InstallDir (see the list above)." }

    # -----------------------------------------------------------------------
    # 9. PyQt6 + PyQt6-WebEngine
    # -----------------------------------------------------------------------
    $pyqtOk = $true
    if (-not $SkipPyQt) {
        Write-Step 'PyQt6 / PyQt6-WebEngine'
        $qmake = Join-Path $InstallDir 'bin\qmake.exe'
        if (-not (Test-Path $qmake)) { throw "$qmake not found" }
        $qtInstalled = [version](& $qmake -query QT_VERSION)
        Write-Ok "Qt in ${InstallDir}: $qtInstalled"

        # Qt DLLs must be found both while building and while importing PyQt6
        if (-not (Test-Path (Join-Path $InstallDir 'bin\Qt6Multimedia.dll'))) {
            throw "There is no Qt Multimedia in $InstallDir - PyQt6 would be built without QtMultimedia. Run with -Mode AddMultimedia first."
        }

        # Qt is built with MSVC, but MinGW settings may have ended up in .pri files (MinGW was in PATH during an earlier build):
        #   -lmingw32       -> qmake adds mingw32.lib, linking fails;
        #   QT_NEEDS_QMAIN  -> QtGui headers rename main to qMain, and Qt6EntryPoint.lib
        #                      cannot find main (LNK2019) - QtGui/QtWidgets silently disappear from PyQt6.
        Get-ChildItem (Join-Path $InstallDir 'mkspecs\modules') -Filter *.pri | ForEach-Object {
            $c = [IO.File]::ReadAllText($_.FullName)
            $n = $c -replace '\s*-lmingw32', '' -replace '(?m)^(QT\.\w+\.DEFINES\s*=.*?)\s*\bQT_NEEDS_QMAIN\b', '$1'
            if ($n -ne $c) {
                $bak = "$($_.FullName).bak"
                if (-not (Test-Path $bak)) { Copy-Item $_.FullName $bak }
                [IO.File]::WriteAllText($_.FullName, $n)
                Write-Ok "Removed MinGW settings from $($_.Name) (backup: $($_.Name).bak)"
            }
        }

        $qtBin = Join-Path $InstallDir 'bin'
        if (($env:Path -split ';') -notcontains $qtBin) { $env:Path = "$qtBin;$env:Path" }

        function Get-PyPISdist([string]$Package, [string]$Want) {
            $info = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -UseBasicParsing
            $withSdist = @{}
            foreach ($prop in $info.releases.PSObject.Properties) {
                $sd = @($prop.Value | Where-Object { $_.packagetype -eq 'sdist' -and -not $_.yanked })
                if ($sd.Count -gt 0 -and $prop.Name -match '^\d+(\.\d+){1,3}$') { $withSdist[$prop.Name] = $sd[0].url }
            }
            if ($Want) {
                if (-not $withSdist.ContainsKey($Want)) { throw "$Package ${Want}: no such version with sources on PyPI." }
                return @{ Version = $Want; Url = $withSdist[$Want] }
            }
            $vers = $withSdist.Keys | ForEach-Object { [version]$_ } | Sort-Object -Descending
            $pick = $vers | Where-Object { $_.Major -eq $qtInstalled.Major -and $_.Minor -eq $qtInstalled.Minor } | Select-Object -First 1
            if (-not $pick) {
                $pick = $vers | Where-Object { $_ -le $qtInstalled } | Select-Object -First 1
                Write-Warn2 "$Package for Qt $($qtInstalled.Major).$($qtInstalled.Minor) not found, using $pick (some newer APIs may be missing)."
            }
            if (-not $pick) { throw "Could not find a $Package version for Qt $qtInstalled." }
            return @{ Version = $pick.ToString(); Url = $withSdist[$pick.ToString()] }
        }

        # PyQt6-WebEngine takes the .sip files (QtCore/QtCoremod.sip etc.) from the installed PyQt6
        # while building, so the PyQt6 wheel is installed into the build venv first.
        # Modules that must be present in each wheel
        $requiredMods = @{
            'PyQt6'           = @('QtCore', 'QtGui', 'QtWidgets', 'QtMultimedia', 'QtMultimediaWidgets')
            'PyQt6-WebEngine' = @('QtWebEngineCore', 'QtWebEngineWidgets')
        }
        function Get-WheelMissing([string]$Wheel, [string]$Package) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($Wheel)
            try { $names = @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
            return @($requiredMods[$Package] | Where-Object { $names -notcontains "PyQt6/$_.pyd" })
        }

        # The wheel goes into the build venv: PyQt6-WebEngine takes the .sip files from the installed PyQt6.
        # Your main Python is not touched - the project gets PyQt6 from the bundle (step 11).
        function Install-PyQtWheel([string]$Wheel) {
            Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--force-reinstall', '--no-deps', $Wheel)
        }

        function Build-SipWheel([string]$Package, [string]$Want, [string[]]$ExtraArgs) {
            $sd = Get-PyPISdist $Package $Want
            Write-Info "$Package $($sd.Version)"

            # A finished wheel of the same version exists - do not rebuild (unless -Clean)
            $wheelPrefix = ($Package.ToLower() -replace '-', '_') + "-$($sd.Version)-"
            $ready = Get-ChildItem $wheelsDir -Filter "$wheelPrefix*.whl" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ready -and (Get-WheelMissing $ready.FullName $Package).Count -gt 0) {
                Write-Warn2 "Existing wheel $($ready.Name) is incomplete - rebuilding"
                $ready = $null
            }
            if ($ready -and -not $Clean) {
                Write-Info "Found finished wheel $($ready.Name), build skipped"
                Install-PyQtWheel $ready.FullName
                Write-Ok "$Package installed: $($ready.Name)"
                return
            }
            $root = Join-Path $DevDir "pyqt\$Package-$($sd.Version)"
            if ($Clean -and (Test-Path $root)) { Remove-Item -Recurse -Force $root }
            New-Item -ItemType Directory -Force $root | Out-Null
            $archive = Join-Path $DownloadsDir (Split-Path $sd.Url -Leaf)
            if (-not (Test-Path $archive)) { Invoke-WebRequest -Uri $sd.Url -OutFile $archive -UseBasicParsing }
            $srcRoot = Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'pyproject.toml') } | Select-Object -First 1
            if (-not $srcRoot) {
                Invoke-Native tar @('-xzf', $archive, '-C', $root)
                $srcRoot = Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'pyproject.toml') } | Select-Object -First 1
            }
            Push-Location $srcRoot.FullName
            try {
                Get-ChildItem -Filter *.whl | Remove-Item -Force
                if (Test-Path 'build') { Remove-Item -Recurse -Force 'build' }
                $a = @('--qmake', $qmake, '--jobs', "$Jobs", '--build-dir', 'build') + $ExtraArgs
                Invoke-Native $sipWheel $a
                $whl = Get-ChildItem -Filter *.whl | Select-Object -First 1
                if (-not $whl) { throw "sip-wheel produced no wheel for $Package" }
                $miss = Get-WheelMissing $whl.FullName $Package
                if ($miss.Count -gt 0) {
                    throw "Modules missing from the $Package wheel: $($miss -join ', '). Run sip-wheel with --verbose in $($srcRoot.FullName) to see why the module check failed."
                }
                Copy-Item $whl.FullName $wheelsDir -Force
                Install-PyQtWheel $whl.FullName
                Write-Ok "$Package installed: $($whl.Name)"
            }
            finally { Pop-Location }
        }

        $wheelsDir = Join-Path $DevDir 'wheels'
        New-Item -ItemType Directory -Force $wheelsDir | Out-Null

        # PyPI wheels bring their own Qt (without codecs) - remove them from the build venv
        # (in PS 5.1, redirecting stderr with ErrorActionPreference=Stop aborts the script)
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $BuildPy -m pip uninstall -y PyQt6 PyQt6-Qt6 PyQt6-WebEngine PyQt6-WebEngine-Qt6 2>&1 | Out-Null
        $ErrorActionPreference = $eap

        # Build tools go into the venv (same Python version, so the same wheel ABI);
        # the project gets only the finished wheels and the PyQt6-sip runtime.
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'sip>=6.8', 'PyQt-builder>=1.16')
        $sipWheel = Join-Path $BuildVenv 'Scripts\sip-wheel.exe'
        if (-not (Test-Path $sipWheel)) { throw "$sipWheel not found" }
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'PyQt6-sip>=13.13,<14')

        # PyQt6 includes QtMultimedia/QtMultimediaWidgets automatically if they exist in Qt
        Build-SipWheel 'PyQt6' $PyQtVersion @('--confirm-license')
        Build-SipWheel 'PyQt6-WebEngine' $PyQtWebEngineVersion @()

        # Leftovers of PyQt6-Qt6 / PyQt6-WebEngine-Qt6 from PyPI: if a PyQt6\Qt6 folder exists,
        # PyQt6 embeds a qt.conf with Prefix = PyQt6\Qt6, and Qt looks for plugins there instead of $InstallDir
        # ("Could not find the Qt platform plugin windows").
        foreach ($py in @($BuildPy)) {
            $pkgDir = & $py -c "import os, PyQt6; print(os.path.dirname(PyQt6.__file__))"
            $leftover = Join-Path $pkgDir 'Qt6'
            if ($pkgDir -and (Test-Path $leftover)) {
                Remove-Item -Recurse -Force $leftover
                Write-Ok "Removed PyQt6-Qt6 leftovers from PyPI: $leftover"
            }
        }

        # Smoke test: import the modules
        $test = @'
from PyQt6 import QtCore, QtMultimedia, QtMultimediaWidgets
from PyQt6 import QtWebEngineCore, QtWebEngineWidgets
print("PyQt", QtCore.PYQT_VERSION_STR, "/ Qt", QtCore.QT_VERSION_STR)
'@
        $testFile = Join-Path $DevDir 'pyqt\import_test.py'
        Set-Content -Path $testFile -Value $test -Encoding ASCII
        & $BuildPy $testFile
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Importing QtMultimedia and QtWebEngine from PyQt6 works' }
        else { throw 'Importing PyQt6 modules failed - see the log above.' }

        if ($AddQtToPath) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (($userPath -split ';') -notcontains $qtBin) {
                [Environment]::SetEnvironmentVariable('Path', "$qtBin;$userPath", 'User')
                Write-Ok "$qtBin added to the user PATH (applies to new windows)"
            }
        }
        else {
            Write-Info "To use this Qt directly (outside the bundle), $qtBin must be in PATH (or run the script with -AddQtToPath)."
        }
    }

    # -----------------------------------------------------------------------
    # 10. Portable bundle: Qt runtime wheel + installer
    # -----------------------------------------------------------------------
    if (-not $SkipPyQt) {
        Write-Step "Bundle -> $BundleDir"
        Invoke-Native $BuildPy @((Join-Path $ScriptDir 'make-bundle.py'), '--qt', $InstallDir, '--wheels', $wheelsDir,
                                 '--out', $BundleDir, '--files', (Join-Path $ScriptDir 'bundle-files'))
        foreach ($pat in 'pyqt6-*.whl', 'pyqt6_webengine-*.whl', 'pyqt6_qt6_local-*.whl', 'install.ps1', 'check.py') {
            if (-not (Get-ChildItem $BundleDir -Filter $pat -ErrorAction SilentlyContinue)) { throw "$pat is missing from the bundle" }
        }
        Write-Ok "Bundle ready: $BundleDir (it can be copied to other PCs)"

        # -------------------------------------------------------------------
        # 11. Install into the project venv + .mp4 check
        # -------------------------------------------------------------------
        if ($Project) {
            Write-Step "Installing into the project: $ProjectVenv"
            New-Item -ItemType Directory -Force $Project | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BundleDir 'install.ps1') -Venv $ProjectVenv -Python $Python -Yes
            switch ($LASTEXITCODE) {
                0       { Write-Ok "PyQt6 installed into $ProjectVenv, .mp4 is supported" }
                2       { Write-Warn2 'Installed, but the .mp4 check failed - see the output above'; $pyqtOk = $false }
                default { throw "Installation into $ProjectVenv failed (code $LASTEXITCODE)" }
            }

            # ---------------------------------------------------------------
            # 12. Project requirements.txt
            # ---------------------------------------------------------------
            if ($doReq) {
                Write-Step 'requirements.txt'
                Update-Requirements $reqFile $BundleDir $Project
            }
        }
    }

    $sw.Stop()
    Write-Step 'Summary'
    Write-Info "Qt:          $InstallDir"
    if (-not $SkipPyQt) {
        Write-Info "Wheels:      $wheelsDir"
        Write-Info "Bundle:      $BundleDir"
        if ($Project) {
            Write-Info "venv:        $ProjectVenv  (activate: $ProjectVenv\Scripts\Activate.ps1)"
            if ($doReq) { Write-Info "requirements: $reqFile" }
        }
    }
    if ($allOk -and $pyqtOk) { Write-Host "`nDone in $([int]$sw.Elapsed.TotalMinutes) min." -ForegroundColor Green }
    else        { Write-Host "`nDone with warnings - see the log." -ForegroundColor Yellow }
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "Log: $LogFile"
Stop-Transcript | Out-Null
