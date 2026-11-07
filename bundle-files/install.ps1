# PyQt6 + PyQt6-WebEngine (Qt with H.264/AAC) installer for Windows 10/11 x64.
# Step 1: preflight checks and questions (nothing is changed yet).
# Step 2: after confirmation - Python (per-user, if needed), venv, wheels, check.
#
#   install.cmd                                  interactive
#   install.cmd -Venv C:\project\.venv -Yes      accept defaults, no questions
param(
    [string]$Venv   = '',
    [string]$Python = '',
    [string]$Proxy  = '',
    [string]$PythonVersion = '3.12.10',
    [switch]$Yes,
    [switch]$SkipCheck
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = $PSScriptRoot

# ---------------------------------------------------------------- helpers
$script:checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    $script:checks.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}
function Show-Checks {
    Write-Host ''
    foreach ($c in $script:checks) {
        $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$c.Status]
        Write-Host ('  [{0,-4}] {1,-22} {2}' -f $c.Status, $c.Check, $c.Detail) -ForegroundColor $color
    }
    Write-Host ''
}
function Ask([string]$Question, [string]$Default) {
    if ($Yes) { Write-Host "$Question [$Default] -> $Default"; return $Default }
    $a = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim().Trim('"')
}
function Ask-YesNo([string]$Question, [bool]$Default) {
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    if ($Yes) { Write-Host "$Question [$d] -> $(if ($Default) {'y'} else {'n'})"; return $Default }
    while ($true) {
        $a = (Read-Host "$Question [$d]").Trim().ToLower()
        if ($a -eq '') { return $Default }
        if ($a -in 'y', 'yes', 'd', 'da') { return $true }
        if ($a -in 'n', 'no', 'net') { return $false }
    }
}
function Get-PythonInfo([string]$exe, [string[]]$pre = @()) {
    try {
        $out = & $exe @pre -c "import sys, struct; print('%d.%d|%d|%s' % (sys.version_info[0], sys.version_info[1], struct.calcsize('P') * 8, sys.executable))" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $v, $bits, $path = "$out".Trim().Split('|')
        return [pscustomobject]@{ Version = [version]$v; Bits = [int]$bits; Path = $path }
    } catch { return $null }
}
function Find-Pythons {
    $list = @()
    $cands = @()
    $cands += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName
    $cands += Get-ChildItem "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object FullName
    foreach ($c in $cands) { $i = Get-PythonInfo $c; if ($i) { $list += $i } }
    if (Get-Command py -ErrorAction SilentlyContinue) { $i = Get-PythonInfo 'py' @('-3'); if ($i) { $list += $i } }
    if (Get-Command python -ErrorAction SilentlyContinue) { $i = Get-PythonInfo 'python'; if ($i) { $list += $i } }   # filters out the Store stub
    $list = $list | Where-Object { $_.Version -ge [version]'3.10' -and $_.Bits -eq 64 }
    return @($list | Sort-Object Path -Unique | Sort-Object Version -Descending)
}
function Test-Internet {
    try {
        Invoke-WebRequest -Uri 'https://pypi.org/simple/pyqt6-sip/' -Method Head -UseBasicParsing -TimeoutSec 8 | Out-Null
        return $true
    } catch { return $false }
}
function Set-SessionProxy([string]$p) {
    $env:HTTPS_PROXY = $p; $env:HTTP_PROXY = $p
    [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy($p, $true)
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
}
function Get-SipWheel([version]$v) {
    $tag = "cp$($v.Major)$($v.Minor)"
    return Get-ChildItem $here -Filter "pyqt6_sip-*-$tag-*win_amd64.whl" -ErrorAction SilentlyContinue | Select-Object -First 1
}

Write-Host ''
Write-Host '=== PyQt6 + WebEngine (H.264/AAC) installer: preflight ===' -ForegroundColor Cyan

# Files copied from the internet / another PC may carry "Mark of the Web" - unblock them
Get-ChildItem $here -File | Unblock-File -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 1. checks
$fatal = $false

# Windows
$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if (-not [Environment]::Is64BitOperatingSystem) { Add-Check 'Windows' 'FAIL' "$($os.Caption): 64-bit Windows is required"; $fatal = $true }
elseif ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { Add-Check 'Windows' 'WARN' "$($os.Caption) on ARM64: x64 emulation, not tested" }
elseif ($build -lt 17763) { Add-Check 'Windows' 'FAIL' "$($os.Caption) build ${build}: Windows 10 1809+ or 11 is required (update Windows manually)"; $fatal = $true }
else { Add-Check 'Windows' 'OK' "$($os.Caption) build $build" }

# Bundle files
$need = 'pyqt6-*.whl', 'pyqt6_webengine-*.whl', 'pyqt6_qt6_local-*.whl', 'check.py'
$missing = @($need | Where-Object { -not (Get-ChildItem $here -Filter $_ -ErrorAction SilentlyContinue) })
if ($missing.Count) { Add-Check 'Bundle files' 'FAIL' "missing: $($missing -join ', ') - copy the whole folder again"; $fatal = $true }
else { Add-Check 'Bundle files' 'OK' $here }

# Media Foundation (missing on Windows "N" editions)
$mfOk = Test-Path "$env:windir\System32\mfplat.dll"
if ($mfOk) { Add-Check 'Media Foundation' 'OK' 'present' }
else { Add-Check 'Media Foundation' 'WARN' 'missing (Windows N edition): QtMultimedia cannot play video without Media Feature Pack' }

# Graphics (VM / RDP / no GPU driver -> WebEngine may show a blank or black window)
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object Name)
$basicGpu = ($gpus.Count -eq 0) -or -not ($gpus | Where-Object { $_ -notmatch 'Basic Display|Basic Render|Hyper-V|VMware SVGA|VirtualBox|Remote Display|Parallels|QXL|Citrix' })
$rdp = "$env:SESSIONNAME" -like 'RDP-*'
if ($basicGpu -or $rdp) { Add-Check 'Graphics' 'WARN' "$(if ($gpus) { $gpus -join '; ' } else { 'no adapter info' })$(if ($rdp) { ' (RDP session)' })" }
else { Add-Check 'Graphics' 'OK' ($gpus -join '; ') }

# Python
$pythons = @(Find-Pythons)
$storePy = $pythons | Where-Object { $_.Path -like '*\WindowsApps\*' -or $_.Path -like '*\Packages\PythonSoftwareFoundation*' }
$installer = Get-ChildItem $here -Filter 'python-3*-amd64.exe' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($Python) {
    $pi = Get-PythonInfo $Python
    if (-not $pi -or $pi.Version -lt [version]'3.10' -or $pi.Bits -ne 64) { Add-Check 'Python' 'FAIL' "-Python $Python is not 3.10+ 64-bit"; $fatal = $true }
    else { Add-Check 'Python' 'OK' "$($pi.Version) $($pi.Path) (-Python)"; $pythons = @($pi) }
} elseif ($pythons.Count) {
    Add-Check 'Python' 'OK' (($pythons | ForEach-Object { "$($_.Version) $($_.Path)" }) -join '; ')
    if ($storePy) { Add-Check 'Python (Store)' 'INFO' 'Microsoft Store Python found: works, but python.org Python is recommended' }
} else {
    Add-Check 'Python' 'WARN' 'no Python 3.10+ 64-bit - will be installed for the current user (no admin rights)'
}
if ($installer) { Add-Check 'Python installer' 'OK' $installer.Name } else { Add-Check 'Python installer' 'INFO' "not in folder (downloaded from python.org only if needed)" }

# Internet (needed only for: Python download, PyQt6-sip for a Python version not in the folder)
$net = Test-Internet
if (-not $net -and $Proxy) { Set-SessionProxy $Proxy; $net = Test-Internet }
Add-Check 'Internet (pypi.org)' $(if ($net) { 'OK' } else { 'WARN' }) $(if ($net) { 'available' } else { 'not available (offline install from the folder)' })

# Disk space on the system drive (Python) - the venv drive is checked after the path question
$sysFree = [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1)
Add-Check "Disk $env:SystemDrive" $(if ($sysFree -ge 1) { 'OK' } else { 'WARN' }) "$sysFree GB free"

Show-Checks
if ($fatal) {
    Write-Host 'Cannot continue: fix the FAIL items above and run install.cmd again.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 2. questions
Write-Host '=== Questions ===' -ForegroundColor Cyan

# 2.1 venv path
if (-not $Venv) { $Venv = Ask 'Path to the project venv (created if missing)' (Join-Path $here '.venv') }
$Venv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Venv)
$venvParent = Split-Path $Venv -Parent
try {
    New-Item -ItemType Directory -Force $venvParent | Out-Null
    $probe = Join-Path $venvParent ".write-test-$PID"
    Set-Content $probe 'x'; Remove-Item $probe -Force
} catch { Write-Host "No write access to $venvParent - choose another path or run as a user that can write there." -ForegroundColor Red; exit 1 }
$vFree = 99
try { $vFree = [math]::Round((Get-PSDrive ($Venv.Substring(0, 1))).Free / 1GB, 1) } catch { }
if ($vFree -lt 1.5) {
    Write-Host "Only $vFree GB free on $($Venv.Substring(0,2)) - about 1.5 GB is needed." -ForegroundColor Yellow
    if (-not (Ask-YesNo 'Continue anyway?' $false)) { exit 1 }
}
$venvExists = Test-Path "$Venv\Scripts\python.exe"

# 2.2 which Python
$basePy = $null; $installPy = $false
if ($venvExists) {
    $vi = Get-PythonInfo "$Venv\Scripts\python.exe"
    if (-not $vi -or $vi.Version -lt [version]'3.10' -or $vi.Bits -ne 64) { Write-Host "Existing venv $Venv is not Python 3.10+ 64-bit - delete it or choose another path." -ForegroundColor Red; exit 1 }
    Write-Host "Existing venv will be used: Python $($vi.Version)"
    $targetVer = $vi.Version
} elseif ($pythons.Count) {
    if ($pythons.Count -gt 1 -and -not $Yes) {
        Write-Host 'Python versions found:'
        for ($i = 0; $i -lt $pythons.Count; $i++) { Write-Host "  $($i + 1)) $($pythons[$i].Version)  $($pythons[$i].Path)" }
        Write-Host "  i) install Python $PythonVersion for the current user"
        $sel = Ask 'Which Python to create the venv with?' '1'
    } else {
        $sel = '1'
        if (-not (Ask-YesNo "Create the venv with Python $($pythons[0].Version) ($($pythons[0].Path))?" $true)) { $sel = 'i' }
    }
    if ($sel -eq 'i') { $installPy = $true }
    else {
        $n = 0; if (-not [int]::TryParse($sel, [ref]$n) -or $n -lt 1 -or $n -gt $pythons.Count) { $n = 1 }
        $basePy = $pythons[$n - 1].Path; $targetVer = $pythons[$n - 1].Version
    }
} else {
    if (-not (Ask-YesNo "Install Python $PythonVersion for the current user (no admin rights, ~100 MB)?" $true)) {
        Write-Host 'Install Python 3.10+ 64-bit from https://www.python.org/downloads/windows/ and run install.cmd again.' -ForegroundColor Yellow
        exit 1
    }
    $installPy = $true
}
if ($installPy) { $targetVer = [version]($PythonVersion.Split('.')[0..1] -join '.') }

# 2.3 internet / proxy - only if something must be downloaded
$needNet = @()
if ($installPy -and -not $installer) { $needNet += "Python $PythonVersion installer" }
if (-not (Get-SipWheel $targetVer)) { $needNet += "PyQt6-sip for Python $targetVer" }
if ($needNet.Count -and -not $net) {
    Write-Host "Internet is needed for: $($needNet -join ', ')" -ForegroundColor Yellow
    $p = if ($Yes) { '' } else { Read-Host 'Proxy URL (e.g. http://proxy:3128), empty if none' }
    if ($p) { Set-SessionProxy $p.Trim(); $net = Test-Internet }
    if (-not $net) {
        Write-Host 'Still no internet. Either connect this PC, or put the missing files into the bundle folder:' -ForegroundColor Red
        if ($installPy -and -not $installer) { Write-Host "  python-$PythonVersion-amd64.exe from https://www.python.org/downloads/windows/" }
        if (-not (Get-SipWheel $targetVer)) { Write-Host "  pyqt6_sip-*-cp$($targetVer.Major)$($targetVer.Minor)-*win_amd64.whl from https://pypi.org/project/PyQt6-sip/#files" }
        exit 1
    }
}

# 2.4 Media Feature Pack (needs admin + reboot - cannot be done silently)
$installMfp = $false
if (-not $mfOk) {
    Write-Host 'Media Feature Pack is missing. It needs admin rights (UAC prompt) and a reboot.' -ForegroundColor Yellow
    $installMfp = Ask-YesNo 'Try to install Media Feature Pack now?' $false
    if (-not $installMfp) { Write-Host '  Later: Settings > Apps > Optional features > Add a feature > "Media Feature Pack".' }
}

# 2.5 software rendering for WebEngine (VM / RDP / basic display driver)
$softGl = $false
if ($basicGpu -or $rdp) {
    Write-Host 'No hardware GPU driver detected (VM, RDP or basic display driver). WebEngine may show a blank window.' -ForegroundColor Yellow
    Write-Host '  Installing the real GPU driver is a manual step; until then software rendering can be used.'
    $softGl = Ask-YesNo 'Enable software rendering for Qt WebEngine in this venv?' $true
}

# 2.6 summary
Write-Host ''
Write-Host '=== Plan ===' -ForegroundColor Cyan
if ($installPy) { Write-Host "  - install Python $PythonVersion for the current user$(if (-not $installer) { ' (download from python.org)' })" }
if (-not $venvExists) { Write-Host "  - create venv $Venv$(if ($basePy) { " with $basePy" })" } else { Write-Host "  - use venv $Venv" }
Write-Host '  - remove PyQt6 / PyQt6-Qt6 / PyQt6-WebEngine(-Qt6) from PyPI in the venv, if present'
Write-Host '  - install PyQt6, PyQt6-WebEngine, PyQt6-Qt6-Local, PyQt6-sip from this folder'
if ($installMfp) { Write-Host '  - install Media Feature Pack (UAC prompt, reboot required)' }
if ($softGl) { Write-Host '  - enable software rendering for WebEngine in this venv' }
if (-not $SkipCheck) { Write-Host '  - run check.py (.mp4 support)' }
Write-Host ''
if (-not (Ask-YesNo 'Start?' $true)) { Write-Host 'Cancelled, nothing was changed.'; exit 0 }

# ---------------------------------------------------------------- 3. install
Write-Host ''
Write-Host '=== Installing ===' -ForegroundColor Cyan

if ($installPy) {
    $inst = if ($installer) { $installer.FullName } else {
        $f = Join-Path $env:TEMP "python-$PythonVersion-amd64.exe"
        $url = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-amd64.exe"
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $f -UseBasicParsing
        $f
    }
    Write-Host "Installing Python $PythonVersion (1-2 min)..."
    $p = Start-Process -FilePath $inst -Wait -PassThru -ArgumentList @(
        '/quiet', 'InstallAllUsers=0', 'PrependPath=1', 'Include_launcher=0',
        'Include_test=0', 'Include_doc=0', 'Shortcuts=0')
    if ($p.ExitCode -ne 0) { throw "Python installer failed with code $($p.ExitCode)" }
    $tag = ($PythonVersion.Split('.')[0..1] -join '')
    $basePy = "$env:LOCALAPPDATA\Programs\Python\Python$tag\python.exe"
    if (-not (Test-Path $basePy)) { throw "Python installed but $basePy not found" }
}

if (-not $venvExists) {
    Write-Host "Creating venv $Venv"
    & $basePy -m venv $Venv
    if ($LASTEXITCODE -ne 0) { throw 'venv creation failed' }
}
$py = "$Venv\Scripts\python.exe"

$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $py -m pip uninstall -y PyQt6 PyQt6-Qt6 PyQt6-WebEngine PyQt6-WebEngine-Qt6 PyQt6-Qt6-Local 2>&1 | Out-Null
$ErrorActionPreference = $eap
$leftover = "$Venv\Lib\site-packages\PyQt6"
if (Test-Path $leftover) { Remove-Item -Recurse -Force $leftover }   # leftovers of PyPI PyQt6-Qt6

if (Get-SipWheel $targetVer) { & $py -m pip install --disable-pip-version-check --no-index --find-links $here 'PyQt6-sip>=13.13,<14' }
else { & $py -m pip install --disable-pip-version-check 'PyQt6-sip>=13.13,<14' }
if ($LASTEXITCODE -ne 0) { throw 'PyQt6-sip install failed' }

& $py -m pip install --disable-pip-version-check --no-index --find-links $here PyQt6 PyQt6-WebEngine PyQt6-Qt6-Local
if ($LASTEXITCODE -ne 0) { throw 'PyQt6 install failed' }

if ($softGl) {
    $site = & $py -c "import sysconfig; print(sysconfig.get_paths()['purelib'])"
    Set-Content -Path (Join-Path $site 'pyqt_local_softgl.pth') -Encoding ASCII -Value `
        "import os; os.environ.setdefault('QTWEBENGINE_CHROMIUM_FLAGS', '--disable-gpu')"
    Write-Host 'Software rendering enabled (remove pyqt_local_softgl.pth from site-packages to disable).'
}

if ($installMfp) {
    Write-Host 'Installing Media Feature Pack (confirm the UAC prompt)...'
    $cmd = 'try { $c = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object Name -like ''Media.MediaFeaturePack*''; if (-not $c) { exit 2 }; $c | Add-WindowsCapability -Online -ErrorAction Stop | Out-Null; exit 0 } catch { exit 1 }'
    try {
        $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-Command', $cmd
        if ($p.ExitCode -eq 0) { Write-Host 'Media Feature Pack installed - REBOOT the PC before using video.' -ForegroundColor Yellow }
        elseif ($p.ExitCode -eq 2) { Write-Host 'Media Feature Pack is not offered as an optional feature on this Windows build - download it from Microsoft for your Windows version.' -ForegroundColor Yellow }
        else { Write-Host 'Media Feature Pack was not installed - install it manually (Settings > Apps > Optional features).' -ForegroundColor Yellow }
    } catch { Write-Host 'UAC was declined - install Media Feature Pack manually (Settings > Apps > Optional features).' -ForegroundColor Yellow }
}

Write-Host "`nInstalled into $Venv" -ForegroundColor Green
& $py -m pip list --disable-pip-version-check | Select-String 'PyQt'

if (-not $SkipCheck) {
    Write-Host "`n=== check ===" -ForegroundColor Cyan
    & $py "$here\check.py"
    $checkOk = ($LASTEXITCODE -eq 0)
    if ($checkOk) { Write-Host 'OK: .mp4 is supported' -ForegroundColor Green }
    else { Write-Host 'Check failed - see output above and README.md (Troubleshooting)' -ForegroundColor Red }
}
Write-Host "`nActivate: $Venv\Scripts\Activate.ps1"
if (-not $SkipCheck -and -not $checkOk) { exit 2 }
exit 0
