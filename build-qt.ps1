#Requires -Version 5.1
<#
.SYNOPSIS
    Полный цикл на чистой Windows: окружение -> git clone Qt -> CMake configure -> сборка
    Qt WebEngine (Chromium) с H.264/AAC и Qt Multimedia -> проверка -> колёса PyQt6 /
    PyQt6-WebEngine -> переносимый комплект -> установка в venv проекта -> requirements.txt.

    Подготовка окружения и сборка Qt 6 под Windows/MSVC:
    Qt WebEngine (с proprietary codecs, т.е. H.264/AAC/.mp4) + Qt Multimedia
    + Python-биндинги PyQt6 и PyQt6-WebEngine, собранные под этот Qt.

.DESCRIPTION
    За один запуск:
      1. Проверяет и при необходимости ставит инструменты (VS 2022 Build Tools, Git, CMake,
         Ninja, Python + html5lib, Node.js, Strawberry Perl, win_flex_bison, gperf).
      2. Входит в окружение MSVC x64 (аналог "x64 Native Tools Command Prompt").
      3. Готовит исходники (клонирует qt5.git или доинициализирует недостающие модули).
      4. (Опционально) скачивает FFmpeg для FFmpeg-бэкенда Qt Multimedia.
      5. Выбирает режим сборки и собирает:
           AddMultimedia - WebEngine уже установлен с кодеками -> дособираются только
                           qtshadertools (если нет) и qtmultimedia. Минуты.
           Full          - полная сборка qtwebengine + qtmultimedia. Часы.
           Auto          - выбрать автоматически (по умолчанию).
           PyQtOnly      - Qt не трогать, только пересобрать PyQt6 / PyQt6-WebEngine.
      6. Собирает колёса PyQt6 и PyQt6-WebEngine из исходников (sip-wheel) против
         $InstallDir, ставит их в выбранный Python и кладёт .whl в $DevDir\wheels.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-qt.ps1
    (интерактивно: проверка, вопросы, план, затем вся цепочка)
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

    # Нужна только если исходников в $SrcDir ещё нет (например 6.8.3).
    [string]$QtVersion = '',

    # Собрать FFmpeg-бэкенд Qt Multimedia (иначе - нативный Windows Media Foundation).
    [switch]$UseFFmpeg,
    # Своя ссылка на zip с shared-сборкой FFmpeg (include/lib/bin внутри).
    [string]$FFmpegUrl = '',

    # Число параллельных задач. 0 = автоматически (по ядрам и памяти).
    [int]$Jobs = 0,

    # Только проверить окружение и показать, что будет сделано.
    [switch]$CheckOnly,
    # Не ставить недостающие инструменты, только проверять.
    [switch]$SkipPrereqInstall,
    # Удалить каталоги сборки перед конфигурацией.
    [switch]$Clean,

    # Python, для которого собираются биндинги (64-bit CPython 3.9+).
    [string]$Python = 'python',
    # Не собирать PyQt6 / PyQt6-WebEngine.
    [switch]$SkipPyQt,
    # Версии PyQt6 / PyQt6-WebEngine. Пусто = последняя с той же major.minor, что и Qt.
    [string]$PyQtVersion = '',
    [string]$PyQtWebEngineVersion = '',
    # Добавить $InstallDir\bin в PATH пользователя (нужно, чтобы PyQt6 нашёл Qt DLL).
    [switch]$AddQtToPath,

    # Проект, куда поставить PyQt6 (venv + requirements.txt). Пусто = спросить; '-' = не ставить.
    [string]$Project = '',
    # venv проекта (по умолчанию <Project>\.venv)
    [string]$ProjectVenv = '',
    # Куда положить переносимый комплект (по умолчанию <Project>\vendor\pyqt-bundle или $DevDir\pyqt-bundle)
    [string]$BundleDir = '',
    # Не менять requirements.txt проекта
    [switch]$NoRequirements,
    # Прокси для загрузок (git, pip, winget, Invoke-WebRequest)
    [string]$Proxy = '',
    # Не задавать вопросов, брать значения по умолчанию
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # ускоряет Invoke-WebRequest в PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir    = $PSScriptRoot
$ToolsDir     = Join-Path $DevDir 'tools'
$DownloadsDir = Join-Path $DevDir 'downloads'
$LogsDir      = Join-Path $DevDir 'logs'
$ModulesBuild = "$BuildDir-modules"
$ExtraPaths   = New-Object System.Collections.Generic.List[string]

# Версии вспомогательных утилит, которые качаются напрямую
$WinFlexBisonUrl = 'https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip'
$GperfUrl        = 'https://downloads.sourceforge.net/project/gnuwin32/gperf/3.0.1/gperf-3.0.1-bin.zip'

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok]  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "        $msg" }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments = @())
    Write-Host "  > $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Команда завершилась с кодом ${LASTEXITCODE}: $Exe $($Arguments -join ' ')" }
}

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
    $env:Path = (@($ExtraPaths) + @($machine, $user, $wingetLinks) | Where-Object { $_ }) -join ';'
    Remove-ForeignToolchains
}

# Убирает из PATH MinGW/MSYS/Cygwin и C:\Strawberry\c\bin: там лежат gcc, свой cmake, zstd и т.п.,
# которые подхватываются вместо MSVC-инструментов и портят сборку (в т.ч. -lmingw32 в .pri файлах).
function Remove-ForeignToolchains {
    $bad = '\\Strawberry\\c\\bin|\\msys64\\|\\msys2\\|\\mingw(32|64)?\\|\\mingw(32|64)?$|\\cygwin(64)?\\|\\ucrt64\\|\\clang64\\'
    $parts = $env:Path -split ';' | Where-Object { $_ }
    $removed = @($parts | Where-Object { $_ -match $bad })
    if ($removed.Count -gt 0) {
        $env:Path = ($parts | Where-Object { $_ -notmatch $bad }) -join ';'
        foreach ($r in $removed) { Write-Info "Убрано из PATH (на время сборки): $r" }
    }
}

function Add-ToolPath($dir) {
    if (-not $ExtraPaths.Contains($dir)) { $ExtraPaths.Insert(0, $dir) }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

function Install-WithWinget([string]$Id, [string]$Override = '') {
    if ($SkipPrereqInstall) { throw "Не найдено: $Id (установка отключена ключом -SkipPrereqInstall)" }
    if (-not (Test-Cmd 'winget')) {
        throw "winget не найден. Установите 'App Installer' из Microsoft Store или поставьте $Id вручную (см. README)."
    }
    Write-Info "Установка $Id через winget..."
    $wargs = @('install', '--id', $Id, '-e', '--accept-package-agreements', '--accept-source-agreements', '--silent')
    if ($Override) { $wargs += @('--override', $Override) }
    & winget @wargs
    # -1978335189 = уже установлено
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget не смог установить $Id (код $LASTEXITCODE)"
    }
    Update-PathFromRegistry
}

function Get-ZipTool([string]$Url, [string]$Name) {
    $dest = Join-Path $ToolsDir $Name
    if (Test-Path $dest) { return $dest }
    if ($SkipPrereqInstall) { throw "Не найдено: $Name (установка отключена)" }
    New-Item -ItemType Directory -Force $DownloadsDir | Out-Null
    $zip = Join-Path $DownloadsDir "$Name.zip"
    Write-Info "Скачивание $Url"
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
    # -> [pscustomobject]@{Version; Bits; Path} или $null (в т.ч. для заглушки Microsoft Store)
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
        # любой HTTP-ответ (403/405...) значит, что сайт доступен
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
        # ищем H.264-декодер FFmpeg прямо в Qt6WebEngineCore.dll
        if (Test-DllHasH264 (Join-Path $InstallDir 'bin\Qt6WebEngineCore.dll')) { $st.Codecs = 'yes' } else { $st.Codecs = 'no' }
    }
    return $st
}

function Get-FFmpegUrl([string]$Want) {
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'build-qt.ps1' }
    } catch {
        throw "Не удалось получить список сборок FFmpeg с GitHub ($($_.Exception.Message)). Укажите -FFmpegUrl <zip win64 lgpl shared> или распакуйте FFmpeg в $DevDir\ffmpeg (include, lib, bin)."
    }
    $cands = foreach ($a in $rel.assets) {
        if ($a.name -match '^ffmpeg-n(\d+\.\d+).*-win64-lgpl-shared-\1\.zip$') {
            [pscustomobject]@{ Ver = [version]$Matches[1]; Name = $a.name; Url = $a.browser_download_url }
        }
    }
    $cands = @($cands)
    if (-not $cands.Count) { throw 'В последнем релизе BtbN/FFmpeg-Builds нет win64 lgpl shared сборок - укажите -FFmpegUrl.' }
    $pick = $cands | Where-Object { $_.Ver -eq [version]$Want } | Select-Object -First 1
    if (-not $pick) {
        $pick = $cands | Where-Object { $_.Ver.Major -eq ([version]$Want).Major } | Sort-Object Ver -Descending | Select-Object -First 1
    }
    if (-not $pick) { $pick = $cands | Sort-Object Ver -Descending | Select-Object -First 1 }
    if ($pick.Ver -ne [version]$Want) { Write-Warn2 "FFmpeg $Want у BtbN нет, беру $($pick.Ver) ($($pick.Name))" }
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
    # Признаки proprietary codecs в Chromium (имена символов в release-сборке вырезаны, а пути
    # исходников остаются): MP4-парсер media/formats/mp4 и H.264-декодер WebRTC собираются
    # только с proprietary_codecs.
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
    if ($wheels.Count -lt 3) { throw "В $Bundle нет всех трёх колёс PyQt6 / PyQt6-WebEngine / PyQt6-Qt6-Local" }
    $lines = @()
    if (Test-Path $ReqFile) {
        Copy-Item $ReqFile "$ReqFile.bak" -Force
        $lines = @(Get-Content $ReqFile)
    }
    $marker = '# --- PyQt6 + WebEngine (H.264/AAC), local wheels - managed by build-qt.ps1 ---'
    # Убираем PyQt6/PyQt6-Qt6/PyQt6-WebEngine(-Qt6)/PyQt6-sip по имени и старые ссылки на наши колёса
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
        if ($r -notmatch $wheelPat -and $r.Trim() -ne 'PyQt6-sip>=13.13,<14') { Write-Info "Убрано из requirements: $r" }
    }
    Write-Ok "requirements.txt обновлён: $ReqFile$(if (Test-Path "$ReqFile.bak") { ' (копия: requirements.txt.bak)' })"
}

# ---------------------------------------------------------------------------
# 0. Лог
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force $DevDir, $ToolsDir, $DownloadsDir, $LogsDir | Out-Null
$LogFile = Join-Path $LogsDir ("build-qt-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    # -----------------------------------------------------------------------
    # 0. Предварительная проверка и вопросы (до подтверждения ничего не меняется)
    # -----------------------------------------------------------------------
    Write-Step 'Предварительная проверка'
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
    if (-not [Environment]::Is64BitOperatingSystem) { Add-Check 'Windows' 'FAIL' "$($os.Caption): нужна 64-битная Windows"; $fatal = $true }
    elseif ($osBuild -lt 17763) { Add-Check 'Windows' 'FAIL' "сборка ${osBuild}: нужна Windows 10 1809+ или 11 (обновите Windows вручную)"; $fatal = $true }
    else { Add-Check 'Windows' 'OK' "$($os.Caption), сборка $osBuild" }

    # Файлы набора рядом со скриптом
    if (-not $SkipPyQt) {
        $kit = @('make-bundle.py', 'bundle-files\install.ps1', 'bundle-files\install.cmd', 'bundle-files\check.py', 'bundle-files\README.md')
        $kitMissing = @($kit | Where-Object { -not (Test-Path (Join-Path $ScriptDir $_)) })
        if ($kitMissing.Count) { Add-Check 'Файлы набора' 'FAIL' "нет рядом со скриптом: $($kitMissing -join ', ') - скопируйте папку целиком"; $fatal = $true }
        else { Add-Check 'Файлы набора' 'OK' $ScriptDir }
        Get-ChildItem $ScriptDir -Recurse -File -Include *.ps1, *.py, *.cmd -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    }

    # Что уже есть
    $haveSrc = Test-Path (Join-Path $SrcDir 'qtbase\.cmake.conf')
    $qtState = Get-QtState
    $srcVer  = Get-QtVersionFromSource
    $predMode = $Mode
    if ($predMode -eq 'Auto') {
        if ($qtState.WebEngine -and $qtState.Codecs -eq 'yes') {
            if ($qtState.Multimedia) { $predMode = 'PyQtOnly' } else { $predMode = 'AddMultimedia' }
        } else { $predMode = 'Full' }
    }
    Add-Check 'Исходники Qt' $(if ($haveSrc) { 'OK' } else { 'INFO' }) $(if ($haveSrc) { "$SrcDir (Qt $srcVer)" } else { "нет - будет git clone в $SrcDir" })
    Add-Check 'Qt WebEngine' $(if ($qtState.WebEngine) { 'OK' } else { 'INFO' }) $(if ($qtState.WebEngine) { "установлен, кодеки H.264/AAC: $($qtState.Codecs)" } else { 'не установлен - будет собран' })
    Add-Check 'Qt Multimedia' $(if ($qtState.Multimedia) { 'OK' } else { 'INFO' }) $(if ($qtState.Multimedia) { 'установлен' } else { 'будет собран' })
    Add-Check 'Режим сборки' 'INFO' $predMode

    # Ресурсы
    $drive = (Split-Path -Qualifier $BuildDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
    $needGB = if ($predMode -eq 'Full') { 100 } else { 15 }
    $minGB  = if ($predMode -eq 'Full') { 60 } else { 8 }
    if ($freeGB -lt $minGB) { Add-Check "Диск ${drive}:" 'FAIL' "свободно $freeGB ГБ, нужно ~$needGB ГБ - освободите место"; $fatal = $true }
    elseif ($freeGB -lt $needGB) { Add-Check "Диск ${drive}:" 'WARN' "свободно $freeGB ГБ, рекомендуется ~$needGB ГБ" }
    else { Add-Check "Диск ${drive}:" 'OK' "свободно $freeGB ГБ" }
    $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($predMode -eq 'Full' -and $ramGB -lt 8) { Add-Check 'Память' 'FAIL' "$ramGB ГБ RAM - для сборки Chromium нужно минимум 8, лучше 16-32"; $fatal = $true }
    elseif ($predMode -eq 'Full' -and $ramGB -lt 16) { Add-Check 'Память' 'WARN' "$ramGB ГБ RAM - сборка будет медленной, возможны падения линковки" }
    else { Add-Check 'Память' 'OK' "$ramGB ГБ RAM, $([Environment]::ProcessorCount) потоков CPU" }

    # Длинные пути (меняется только с правами администратора)
    $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPaths -eq 1) { Add-Check 'Длинные пути' 'OK' 'включены' } else { Add-Check 'Длинные пути' 'WARN' 'выключены - нужны права администратора, чтобы включить' }

    # Инструменты
    $toolIds = [ordered]@{ git = 'Git.Git'; cmake = 'Kitware.CMake'; ninja = 'Ninja-build.Ninja'; node = 'OpenJS.NodeJS.LTS'; perl = 'StrawberryPerl.StrawberryPerl' }
    $toInstall = @()
    foreach ($t in $toolIds.Keys) { if (-not (Test-Cmd $t)) { $toInstall += $t } }
    $pyInfo = Test-PyExe $Python
    $pyOk = $pyInfo -and $pyInfo.Version -ge [version]'3.10' -and $pyInfo.Bits -eq 64
    if (-not $pyOk) {
        if ($Python -ne 'python') { Add-Check 'Python' 'FAIL' "-Python ${Python}: нужен 64-битный Python 3.10+"; $fatal = $true }
        else { $toInstall += 'python' }
    }
    $vsFound = Find-VS
    if (-not $vsFound) { $toInstall += 'Visual Studio 2022 Build Tools (C++)' }
    if ($toInstall.Count) { Add-Check 'Инструменты' 'INFO' "будут установлены: $($toInstall -join ', ')" }
    else { Add-Check 'Инструменты' 'OK' 'git, cmake, ninja, node, perl, python, VS 2022' }
    if ($pyOk) { Add-Check 'Python' 'OK' "$($pyInfo.Version) $($pyInfo.Path)" }
    if ($pyOk -and $pyInfo.Path -like '*\WindowsApps\*') { Add-Check 'Python (Store)' 'WARN' 'Python из Microsoft Store: работает, но надёжнее python.org' }
    $haveWinget = Test-Cmd 'winget'
    if ($toInstall.Count -and -not $haveWinget) {
        Add-Check 'winget' 'FAIL' 'нет winget, а инструменты нужно поставить: установите "App Installer" из Microsoft Store'; $fatal = $true
    } elseif ($haveWinget) { Add-Check 'winget' 'OK' 'есть' }

    # Сеть
    $urls = [ordered]@{}
    if ($predMode -ne 'PyQtOnly') { $urls['code.qt.io'] = 'https://code.qt.io/' }
    $urls['github.com'] = 'https://github.com/'
    if (-not $SkipPyQt) { $urls['pypi.org'] = 'https://pypi.org/simple/pyqt6/' }
    $netBad = @()
    foreach ($k in $urls.Keys) { if (-not (Test-Url $urls[$k])) { $netBad += $k } }
    if ($netBad.Count -and -not $Proxy -and -not $Yes) {
        Show-Checks $checks
        Write-Host "  Нет доступа к: $($netBad -join ', ')" -ForegroundColor Yellow
        $px = Read-Host '  Адрес прокси (например http://proxy:3128), пусто если прокси нет'
        if ($px) {
            $Proxy = $px.Trim(); Set-SessionProxy $Proxy
            $netBad = @($netBad | Where-Object { -not (Test-Url $urls[$_]) })
        }
    }
    if ($netBad.Count) { Add-Check 'Сеть' 'FAIL' "нет доступа к: $($netBad -join ', ') - подключите интернет или укажите -Proxy"; $fatal = $true }
    else {
        $netDetail = (@($urls.Keys) -join ', ') + $(if ($Proxy) { " (прокси $Proxy)" } else { '' })
        Add-Check 'Сеть' 'OK' $netDetail
    }

    # Media Foundation (без неё QtMultimedia не играет видео; ставится вручную / с правами администратора)
    if (Test-Path "$env:windir\System32\mfplat.dll") { Add-Check 'Media Foundation' 'OK' 'есть' }
    else { Add-Check 'Media Foundation' 'WARN' 'нет (Windows N): установите "Media Feature Pack" - иначе проверка видео не пройдёт' }

    Show-Checks $checks
    if ($fatal) { throw 'Есть пункты FAIL - исправьте их и запустите скрипт снова.' }
    if ($CheckOnly) { Write-Step 'Проверка завершена (-CheckOnly), ничего не менялось'; Stop-Transcript | Out-Null; return }

    # ---------------- вопросы
    Write-Step 'Вопросы'
    if ($predMode -ne 'PyQtOnly' -and -not $haveSrc -and -not $QtVersion) {
        $QtVersion = Ask 'Версия Qt для git clone (тег vX.Y.Z на code.qt.io)' '6.11.1'
    }
    if (-not $Project) {
        $Project = Ask 'Папка проекта, куда поставить PyQt6 (venv + requirements.txt); "-" = не ставить' '-'
    }
    if ($Project -eq '-') { $Project = '' }
    if ($Project) {
        $Project = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Project)
        if (-not (Test-Path $Project)) {
            if (-not (Ask-YesNo "Папки $Project нет. Создать?" $true)) { throw 'Папка проекта не существует.' }
        }
        if (-not $ProjectVenv) { $ProjectVenv = Ask 'venv проекта' (Join-Path $Project '.venv') }
        if (-not $BundleDir) { $BundleDir = Ask 'Куда положить комплект колёс (для переноса и requirements.txt)' (Join-Path $Project 'vendor\pyqt-bundle') }
        $reqFile = Join-Path $Project 'requirements.txt'
        $doReq = $false
        if (-not $NoRequirements) {
            $q = if (Test-Path $reqFile) { 'Обновить requirements.txt (PyQt6 по имени будет заменён на пути к колёсам, копия .bak)?' } else { 'Создать requirements.txt с путями к колёсам?' }
            $doReq = Ask-YesNo $q $true
        }
    } else {
        if (-not $BundleDir) { $BundleDir = Join-Path $DevDir 'pyqt-bundle' }
    }
    $BundleDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BundleDir)
    if ($ProjectVenv) { $ProjectVenv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectVenv) }

    if ($predMode -in 'Full', 'AddMultimedia' -and -not $UseFFmpeg -and -not $Yes) {
        $UseFFmpeg = Ask-YesNo 'Бэкенд Qt Multimedia FFmpeg (рекомендуется; Windows Media Foundation устарел с Qt 6.10)? n = Media Foundation' $true
    }

    $doLongPaths = $false; $doDefender = $false
    if ($longPaths -ne 1 -and $predMode -eq 'Full') {
        $doLongPaths = Ask-YesNo 'Включить длинные пути Windows (нужно для Chromium; запрос UAC)?' $true
    }
    if ($predMode -eq 'Full') {
        $doDefender = Ask-YesNo "Добавить $SrcDir, $BuildDir, $InstallDir в исключения Defender (ускоряет сборку в разы; запрос UAC)?" $false
    }
    if ($toInstall -contains 'Visual Studio 2022 Build Tools (C++)') {
        if (-not (Ask-YesNo 'Поставить Visual Studio 2022 Build Tools с C++ (~10 ГБ, запрос UAC)?' $true)) {
            throw 'Без MSVC сборка невозможна. Поставьте VS 2022 с "Разработка классических приложений на C++" и запустите снова.'
        }
    }

    # ---------------- план
    Write-Step 'План'
    if ($toInstall.Count) { Write-Info "1. Установить: $($toInstall -join ', ')" } else { Write-Info '1. Инструменты уже есть' }
    $admList = @()
    if ($doLongPaths) { $admList += 'длинные пути' }
    if ($doDefender)  { $admList += 'исключения Defender' }
    if ($admList.Count) { Write-Info "   С правами администратора (UAC): $($admList -join ', ')" }
    switch ($predMode) {
        'Full'          { if ($haveSrc) { Write-Info "2. Исходники Qt $srcVer есть в $SrcDir - дозагрузить недостающие submodules (включая Chromium)" }
                          else { Write-Info "2. git clone qt5.git v$QtVersion + submodules (qtwebengine с Chromium ~ 10+ ГБ)" }
                          Write-Info "3. CMake configure: -webengine-proprietary-codecs, qtwebengine+qtmultimedia, бэкенд $(if ($UseFFmpeg) { 'FFmpeg' } else { 'Media Foundation' })"
                          Write-Info "4. Сборка и установка в $InstallDir (несколько часов)" }
        'AddMultimedia' { Write-Info "2-4. WebEngine с кодеками уже есть - собрать только qtmultimedia (минуты)" }
        'PyQtOnly'      { Write-Info "2-4. Qt с WebEngine (кодеки) и Multimedia уже есть - сборка Qt пропускается" }
    }
    Write-Info '5. Проверка компонентов: WebEngine, QtWebEngineProcess, Multimedia, плагины, H.264 в Qt6WebEngineCore.dll'
    if (-not $SkipPyQt) {
        Write-Info "6. Колёса PyQt6 + PyQt6-WebEngine из исходников (sip-wheel) -> $DevDir\wheels (30-60 мин)"
        Write-Info "7. Комплект (колесо с Qt runtime + установщик) -> $BundleDir"
        if ($Project) {
            Write-Info "8. Установка в venv проекта $ProjectVenv и проверка .mp4"
            if ($doReq) { Write-Info "9. requirements.txt: $reqFile" }
        }
    }
    $eta = switch ($predMode) { 'Full' { '4-10 ч' } 'AddMultimedia' { '~1-1.5 ч' } default { '~40-70 мин' } }
    Write-Info "Ориентировочно: $eta. Лог: $LogFile"
    Write-Host ''
    if (-not (Ask-YesNo 'Начать?' $true)) { Write-Host 'Отменено, ничего не менялось.'; Stop-Transcript | Out-Null; return }

    if ($Mode -eq 'Auto') { $Mode = $predMode }

    # Действия с правами администратора - одним запросом UAC
    $adm = @()
    if ($doLongPaths) { $adm += "New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force | Out-Null" }
    if ($doDefender)  { $adm += "Add-MpPreference -ExclusionPath '$SrcDir','$BuildDir','$InstallDir','$DevDir'" }
    if ($adm.Count) {
        Write-Step 'Настройки с правами администратора'
        try {
            $pr = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-Command', ("try { " + ($adm -join '; ') + "; exit 0 } catch { exit 1 }")
            if ($pr.ExitCode -eq 0) { Write-Ok 'Применено' } else { Write-Warn2 'Не удалось применить (смотрите README) - продолжаю' }
        } catch { Write-Warn2 'UAC отклонён - продолжаю без этих настроек' }
    }

    # -----------------------------------------------------------------------
    # 1. Системные проверки
    # -----------------------------------------------------------------------
    Write-Step 'Системные проверки'

    $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPaths -eq 1) { Write-Ok 'Длинные пути включены' }
    else { Write-Warn2 'LongPathsEnabled выключен. Желательно включить (см. README), иначе возможны ошибки в Chromium.' }

    $drive = (Split-Path -Qualifier $BuildDir).TrimEnd(':')
    $freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB)
    if ($freeGB -lt 100) { Write-Warn2 "Свободно на ${drive}: $freeGB ГБ. Для полной сборки WebEngine нужно ~100 ГБ." }
    else { Write-Ok "Свободно на ${drive}: $freeGB ГБ" }

    $cores = [Environment]::ProcessorCount
    $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    if ($Jobs -le 0) { $Jobs = [math]::Max(1, [math]::Min($cores, [math]::Floor($ramGB / 2))) }
    Write-Ok "CPU: $cores потоков, RAM: $ramGB ГБ -> параллельных задач: $Jobs"
    if ($ramGB -lt 16) { Write-Warn2 'Меньше 16 ГБ RAM: сборка WebEngine будет очень медленной или упадёт при линковке.' }

    # -----------------------------------------------------------------------
    # 2. Инструменты
    # -----------------------------------------------------------------------
    Write-Step 'Инструменты сборки'
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
        if (-not (Test-Cmd $t.Cmd)) { throw "$($t.Cmd) не найден в PATH после установки. Перезапустите PowerShell и скрипт." }
        Write-Ok "$($t.Cmd): $((Get-Command $t.Cmd).Source)"
    }

    # Python (отсекаем заглушку из Microsoft Store)
    function Test-Python { try { return ((& $Python -c "import sys; print(sys.version_info[0])" 2>$null) -eq '3') } catch { return $false } }
    if (-not (Test-Python)) {
        if ($Python -ne 'python') { throw "Указанный Python не запускается: $Python" }
        Install-WithWinget 'Python.Python.3.12'
        if (-not (Test-Python)) { throw 'Python 3 не запускается. Отключите алиасы python в "Параметры > Приложения > Псевдонимы выполнения" (см. README).' }
    }
    $pyI = Test-PyExe $Python
    if (-not $pyI -or $pyI.Bits -ne 64 -or $pyI.Version -lt [version]'3.10') {
        throw "Нужен 64-битный Python 3.10+ (колёса PyQt6 cp310-abi3), а $Python - $(if ($pyI) { "$($pyI.Version), $($pyI.Bits) бит" } else { 'не запускается' })."
    }
    $Python = (& $Python -c "import sys; print(sys.executable)")
    Write-Ok "python: $(& $Python --version) ($Python)"
    if ($Python -like '*\WindowsApps\*') {
        Write-Warn2 'Это Python из Microsoft Store. Он работает, но для сборки надёжнее Python с python.org (см. README).'
    }

    # Все пакеты для сборки (html5lib, sip, PyQt-builder) ставятся в отдельный venv,
    # чтобы не менять пакеты в вашем основном Python.
    $BuildVenv = Join-Path $DevDir 'venv-build'
    $BuildPy   = Join-Path $BuildVenv 'Scripts\python.exe'
    if (-not $CheckOnly) {
        if (Test-Path $BuildPy) {
            $venvVer = & $BuildPy -c "import sys; print('%d.%d' % sys.version_info[:2])"
            $mainVer = & $Python  -c "import sys; print('%d.%d' % sys.version_info[:2])"
            if ($venvVer -ne $mainVer) { Remove-Item -Recurse -Force $BuildVenv }
        }
        if (-not (Test-Path $BuildPy)) {
            Write-Info "Создание venv для сборки: $BuildVenv"
            Invoke-Native $Python @('-m', 'venv', $BuildVenv)
        }
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'pip', 'html5lib')
        # Qt configure берёт python из PATH - ставим venv первым
        Add-ToolPath (Join-Path $BuildVenv 'Scripts')
        Write-Ok "venv для сборки: $BuildVenv"
    }

    # Node.js >= 14 (для свежих Qt лучше 18+)
    $nodeVer = [version]((& node --version).TrimStart('v'))
    if ($nodeVer.Major -lt 14) { throw "Node.js $nodeVer слишком старый, нужен >= 14 (лучше LTS)." }

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
        Write-Warn2 'Visual Studio 2022 с MSVC не найдена - ставлю Build Tools (это долго, ~10 ГБ).'
        Install-WithWinget 'Microsoft.VisualStudio.2022.BuildTools' `
            '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended'
        $vsPath = Find-VS
        if (-not $vsPath) { throw 'Visual Studio 2022 не найдена после установки. Поставьте вручную (см. README).' }
    }
    Write-Ok "Visual Studio: $vsPath"

    git config --global core.longpaths true | Out-Null

    # -----------------------------------------------------------------------
    # 3. Окружение MSVC x64
    # -----------------------------------------------------------------------
    Write-Step 'Окружение MSVC x64'
    Import-Module (Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    foreach ($p in $ExtraPaths) { if (($env:Path -split ';') -notcontains $p) { $env:Path = "$p;$env:Path" } }
    Remove-ForeignToolchains
    foreach ($t in 'cmake', 'ninja', 'perl', 'python') {
        $src = (Get-Command $t -ErrorAction SilentlyContinue).Source
        if (-not $src) { throw "$t не найден в PATH после очистки от MinGW/MSYS." }
        Write-Ok "${t}: $src"
    }
    # Не даём CMake находить библиотеки из MSYS2/Strawberry (например, zstd из C:\msys64)
    $env:CMAKE_IGNORE_PREFIX_PATH = 'C:/msys64/ucrt64;C:/msys64/mingw64;C:/msys64/clang64;C:/msys64/usr;C:/Strawberry/c'
    if (-not (Test-Cmd 'cl')) { throw 'cl.exe не найден после входа в окружение VS.' }
    Write-Ok "cl.exe: $((Get-Command cl).Source)"
    if (-not $env:WindowsSdkDir) { Write-Warn2 'Windows SDK не обнаружен в окружении - добавьте его в установщике VS.' }
    else { Write-Ok "Windows SDK: $env:WindowsSDKVersion" }

    # -----------------------------------------------------------------------
    # 4. Исходники
    # -----------------------------------------------------------------------
    # Full: всё для WebEngine; AddMultimedia: только то, что собирается поверх установленного Qt
    if ($Mode -eq 'AddMultimedia') { $needModules = @('qtbase', 'qtshadertools', 'qtmultimedia') }
    else {
        $needModules = @('qtbase', 'qtshadertools', 'qtdeclarative', 'qtsvg', 'qtwebchannel',
                         'qtpositioning', 'qttools', 'qtwebengine', 'qtmultimedia')
    }
    $needChromium = ($Mode -eq 'Full')

    if ($Mode -eq 'PyQtOnly') { }
    elseif (-not (Test-Path (Join-Path $SrcDir 'qtbase\.cmake.conf'))) {
        Write-Step 'Исходники Qt'
        if (-not $QtVersion) { throw "Исходников в $SrcDir нет. Укажите версию: -QtVersion 6.11.1" }
        if ($CheckOnly) { Write-Warn2 "Будет клонирован qt5.git v$QtVersion в $SrcDir" }
        else {
            if (-not (Test-Path (Join-Path $SrcDir '.git'))) {
                Invoke-Native git @('clone', '--branch', "v$QtVersion", 'https://code.qt.io/qt/qt5.git', $SrcDir)
            }
            Invoke-Native git (@('-C', $SrcDir, 'submodule', 'update', '--init') + $needModules)
            if ($needChromium) {
                Write-Info 'Загрузка Chromium (qtwebengine/src/3rdparty) - это несколько ГБ, может занять долго...'
                Invoke-Native git @('-C', (Join-Path $SrcDir 'qtwebengine'), 'submodule', 'update', '--init', '--recursive')
            }
        }
    }
    else {
        Write-Step 'Исходники Qt'
        # Доинициализируем только отсутствующие модули, уже скачанные не трогаем
        $missing = @($needModules | Where-Object { -not (Test-Path (Join-Path $SrcDir "$_\CMakeLists.txt")) })
        if ($missing.Count -gt 0) {
            Write-Info "Нет модулей: $($missing -join ', ')"
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
    if ($qtVer) { Write-Ok "Версия Qt в исходниках: $qtVer" }
    if ($Mode -ne 'PyQtOnly') {
        $srcMiss = @($needModules | Where-Object { -not (Test-Path (Join-Path $SrcDir "$_\CMakeLists.txt")) })
        if ($needChromium -and -not (Test-Path (Join-Path $SrcDir 'qtwebengine\src\3rdparty\chromium'))) { $srcMiss += 'qtwebengine\src\3rdparty (Chromium)' }
        if ($srcMiss.Count) { throw "После git не хватает исходников: $($srcMiss -join ', ')" }
        Write-Ok "Исходники на месте: $($needModules -join ', ')$(if ($needChromium) { ' + Chromium' })"
    }

    # -----------------------------------------------------------------------
    # 5. FFmpeg (опционально)
    # -----------------------------------------------------------------------
    $ffmpegDir = Join-Path $DevDir 'ffmpeg'
    if ($UseFFmpeg -and $Mode -ne 'PyQtOnly') {
        Write-Step 'FFmpeg'
        if (-not (Test-Path (Join-Path $ffmpegDir 'include\libavcodec'))) {
            if (-not $FFmpegUrl) {
                # Qt 6.8+ рассчитан на FFmpeg 7.1, Qt 6.5-6.7 - на 6.1. Имена файлов у BtbN меняются,
                # поэтому берём актуальный список из GitHub API.
                if ($qtVer -and $qtVer -lt [version]'6.8') { $ff = '6.1' } else { $ff = '7.1' }
                $FFmpegUrl = Get-FFmpegUrl $ff
            }
            if ($CheckOnly) { Write-Warn2 "Будет скачан $FFmpegUrl" }
            else {
                $zip = Join-Path $DownloadsDir 'ffmpeg.zip'
                $tmp = Join-Path $DownloadsDir 'ffmpeg-extract'
                Write-Info "Скачивание $FFmpegUrl"
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
    # 6. Выбор режима
    # -----------------------------------------------------------------------
    Write-Step 'Выбор режима сборки'
    $webengineInstalled = $qtState.WebEngine
    $codecs = $qtState.Codecs
    Write-Info "WebEngine установлен в ${InstallDir}: $webengineInstalled"
    Write-Info "Proprietary codecs в прошлой сборке: $codecs"

    if ($Mode -eq 'Auto') {
        if ($webengineInstalled -and $codecs -eq 'yes') { $Mode = 'AddMultimedia' } else { $Mode = 'Full' }
    }
    if ($Mode -eq 'Full' -and $codecs -eq 'yes') {
        Write-Warn2 'WebEngine уже собран с кодеками - полная пересборка не обязательна (хватит -Mode AddMultimedia).'
    }
    if ($Mode -in @('AddMultimedia', 'PyQtOnly') -and -not $webengineInstalled) {
        throw "Режим $Mode требует установленного Qt с WebEngine в $InstallDir."
    }
    if ($SkipPyQt) { Write-Info 'PyQt6: пропускается (-SkipPyQt)' }
    else           { Write-Info "PyQt6 / PyQt6-WebEngine: будут собраны для $Python" }
    Write-Ok "Режим: $Mode"
    if ($Mode -eq 'Full') { Write-Warn2 'Полная сборка WebEngine займёт несколько часов.' }


    $env:NINJAJOBS = "-j$Jobs"   # ограничение для внутренней ninja-сборки Chromium

    # -----------------------------------------------------------------------
    # 7. Сборка
    # -----------------------------------------------------------------------
    function Build-QtModule([string]$Name, [string[]]$CmakeArgs = @()) {
        Write-Step "Сборка модуля $Name"
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
        Write-Step 'Сборка Qt пропущена (-Mode PyQtOnly)'
    }
    elseif ($Mode -eq 'AddMultimedia') {
        if (-not (Test-Path (Join-Path $InstallDir 'bin\qsb.exe'))) { Build-QtModule 'qtshadertools' }
        else { Write-Ok 'qtshadertools уже установлен (qsb.exe найден)' }
        Build-QtModule 'qtmultimedia' $mmCmakeArgs
    }
    else {
        Write-Step 'Полная сборка: qtwebengine + qtmultimedia'
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
                throw 'Proprietary codecs не включились - смотрите config.summary.'
            }
            Invoke-Native cmake @('--build', '.', '--parallel', "$Jobs")
            Invoke-Native cmake @('--install', '.')
        }
        finally { Pop-Location }
    }

    # FFmpeg DLL рядом с Qt, чтобы приложения запускались и windeployqt их подхватывал
    if ($UseFFmpeg -and (Test-Path (Join-Path $ffmpegDir 'bin'))) {
        Copy-Item (Join-Path $ffmpegDir 'bin\*.dll') (Join-Path $InstallDir 'bin') -Force
        Write-Ok "FFmpeg DLL скопированы в $InstallDir\bin"
    }

    # -----------------------------------------------------------------------
    # 8. Проверка результата
    # -----------------------------------------------------------------------
    Write-Step 'Проверка результата'
    $expect = @('bin\Qt6WebEngineCore.dll', 'bin\Qt6WebEngineWidgets.dll', 'bin\QtWebEngineProcess.exe',
                'bin\Qt6Multimedia.dll', 'bin\Qt6MultimediaWidgets.dll')
    $allOk = $true
    foreach ($f in $expect) {
        if (Test-Path (Join-Path $InstallDir $f)) { Write-Ok $f } else { Write-Warn2 "Нет: $f"; $allOk = $false }
    }
    $plugins = Get-ChildItem (Join-Path $InstallDir 'plugins\multimedia') -Filter *.dll -ErrorAction SilentlyContinue
    if ($plugins) { $plugins | ForEach-Object { Write-Ok "plugins\multimedia\$($_.Name)" } }
    else { Write-Warn2 'Не найдено ни одного плагина в plugins\multimedia'; $allOk = $false }
    foreach ($f in 'plugins\platforms\qwindows.dll', 'resources\qtwebengine_resources.pak', 'resources\icudtl.dat', 'translations\qtwebengine_locales\en-US.pak') {
        if (Test-Path (Join-Path $InstallDir $f)) { Write-Ok $f } else { Write-Warn2 "Нет: $f"; $allOk = $false }
    }
    $weDll = Join-Path $InstallDir 'bin\Qt6WebEngineCore.dll'
    if ((Test-Path $weDll) -and (Test-DllHasH264 $weDll)) { Write-Ok 'H.264-декодер есть в Qt6WebEngineCore.dll (proprietary codecs)' }
    else { Write-Warn2 'В Qt6WebEngineCore.dll нет H.264 - WebEngine собран без proprietary codecs'; $allOk = $false }
    if (-not $allOk) { throw "Не хватает компонентов Qt в $InstallDir (смотрите список выше)." }

    # -----------------------------------------------------------------------
    # 9. PyQt6 + PyQt6-WebEngine
    # -----------------------------------------------------------------------
    $pyqtOk = $true
    if (-not $SkipPyQt) {
        Write-Step 'PyQt6 / PyQt6-WebEngine'
        $qmake = Join-Path $InstallDir 'bin\qmake.exe'
        if (-not (Test-Path $qmake)) { throw "Не найден $qmake" }
        $qtInstalled = [version](& $qmake -query QT_VERSION)
        Write-Ok "Qt в ${InstallDir}: $qtInstalled"

        # Qt DLL должны находиться и при сборке, и при импорте PyQt6
        if (-not (Test-Path (Join-Path $InstallDir 'bin\Qt6Multimedia.dll'))) {
            throw "В $InstallDir нет Qt Multimedia - PyQt6 соберётся без QtMultimedia. Сначала запустите с -Mode AddMultimedia."
        }

        # Qt собран MSVC, но в .pri могли попасть настройки MinGW (MinGW был в PATH при прошлой сборке):
        #   -lmingw32       -> qmake добавляет mingw32.lib, линковка падает;
        #   QT_NEEDS_QMAIN  -> заголовки QtGui переименовывают main в qMain, и Qt6EntryPoint.lib
        #                      не находит main (LNK2019) - QtGui/QtWidgets молча выпадают из PyQt6.
        Get-ChildItem (Join-Path $InstallDir 'mkspecs\modules') -Filter *.pri | ForEach-Object {
            $c = [IO.File]::ReadAllText($_.FullName)
            $n = $c -replace '\s*-lmingw32', '' -replace '(?m)^(QT\.\w+\.DEFINES\s*=.*?)\s*\bQT_NEEDS_QMAIN\b', '$1'
            if ($n -ne $c) {
                $bak = "$($_.FullName).bak"
                if (-not (Test-Path $bak)) { Copy-Item $_.FullName $bak }
                [IO.File]::WriteAllText($_.FullName, $n)
                Write-Ok "Убраны настройки MinGW из $($_.Name) (копия: $($_.Name).bak)"
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
                if (-not $withSdist.ContainsKey($Want)) { throw "$Package ${Want}: нет такой версии с исходниками на PyPI." }
                return @{ Version = $Want; Url = $withSdist[$Want] }
            }
            $vers = $withSdist.Keys | ForEach-Object { [version]$_ } | Sort-Object -Descending
            $pick = $vers | Where-Object { $_.Major -eq $qtInstalled.Major -and $_.Minor -eq $qtInstalled.Minor } | Select-Object -First 1
            if (-not $pick) {
                $pick = $vers | Where-Object { $_ -le $qtInstalled } | Select-Object -First 1
                Write-Warn2 "$Package для Qt $($qtInstalled.Major).$($qtInstalled.Minor) не найден, беру $pick (часть новых API может быть недоступна)."
            }
            if (-not $pick) { throw "Не удалось подобрать версию $Package под Qt $qtInstalled." }
            return @{ Version = $pick.ToString(); Url = $withSdist[$pick.ToString()] }
        }

        # Колесо ставится и в ваш Python, и в venv для сборки: PyQt6-WebEngine при сборке
        # берёт .sip-файлы (QtCore/QtCoremod.sip и т.д.) из установленного PyQt6.
        # Какие модули обязательно должны быть в колесе
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

        # Колесо ставится в venv сборки: PyQt6-WebEngine при сборке берёт .sip-файлы из установленного PyQt6.
        # Ваш основной Python не трогаем - в проект PyQt6 ставится из комплекта (шаг 8).
        function Install-PyQtWheel([string]$Wheel) {
            Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--force-reinstall', '--no-deps', $Wheel)
        }

        function Build-SipWheel([string]$Package, [string]$Want, [string[]]$ExtraArgs) {
            $sd = Get-PyPISdist $Package $Want
            Write-Info "$Package $($sd.Version)"

            # Уже собранное колесо той же версии - не пересобираем (если не -Clean)
            $wheelPrefix = ($Package.ToLower() -replace '-', '_') + "-$($sd.Version)-"
            $ready = Get-ChildItem $wheelsDir -Filter "$wheelPrefix*.whl" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($ready -and (Get-WheelMissing $ready.FullName $Package).Count -gt 0) {
                Write-Warn2 "Готовое колесо $($ready.Name) неполное - пересобираю"
                $ready = $null
            }
            if ($ready -and -not $Clean) {
                Write-Info "Найдено готовое колесо $($ready.Name), сборка пропущена"
                Install-PyQtWheel $ready.FullName
                Write-Ok "$Package установлен: $($ready.Name)"
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
                if (-not $whl) { throw "sip-wheel не создал колесо для $Package" }
                $miss = Get-WheelMissing $whl.FullName $Package
                if ($miss.Count -gt 0) {
                    throw "В колесе $Package нет модулей: $($miss -join ', '). Запустите sip-wheel с --verbose в $($srcRoot.FullName), чтобы увидеть ошибку проверки модуля."
                }
                Copy-Item $whl.FullName $wheelsDir -Force
                Install-PyQtWheel $whl.FullName
                Write-Ok "$Package установлен: $($whl.Name)"
            }
            finally { Pop-Location }
        }

        $wheelsDir = Join-Path $DevDir 'wheels'
        New-Item -ItemType Directory -Force $wheelsDir | Out-Null

        # Колёса с PyPI тянут свой Qt (без кодеков) - убираем их из venv сборки
        # (в PS 5.1 перенаправление stderr при ErrorActionPreference=Stop прерывает скрипт)
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & $BuildPy -m pip uninstall -y PyQt6 PyQt6-Qt6 PyQt6-WebEngine PyQt6-WebEngine-Qt6 2>&1 | Out-Null
        $ErrorActionPreference = $eap

        # Инструменты сборки - в venv (та же версия Python, значит тот же ABI колёс),
        # в ваш Python ставятся только готовые колёса и рантайм PyQt6-sip.
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'sip>=6.8', 'PyQt-builder>=1.16')
        $sipWheel = Join-Path $BuildVenv 'Scripts\sip-wheel.exe'
        if (-not (Test-Path $sipWheel)) { throw "Не найден $sipWheel" }
        Invoke-Native $BuildPy @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'PyQt6-sip>=13.13,<14')

        # PyQt6 сам включает QtMultimedia/QtMultimediaWidgets, если они есть в Qt
        Build-SipWheel 'PyQt6' $PyQtVersion @('--confirm-license')
        Build-SipWheel 'PyQt6-WebEngine' $PyQtWebEngineVersion @()

        # Остатки PyQt6-Qt6 / PyQt6-WebEngine-Qt6 с PyPI: если папка PyQt6\Qt6 существует,
        # PyQt6 встраивает qt.conf с Prefix = PyQt6\Qt6, и Qt ищет плагины там, а не в $InstallDir
        # ("Could not find the Qt platform plugin windows").
        foreach ($py in @($BuildPy)) {
            $pkgDir = & $py -c "import os, PyQt6; print(os.path.dirname(PyQt6.__file__))"
            $leftover = Join-Path $pkgDir 'Qt6'
            if ($pkgDir -and (Test-Path $leftover)) {
                Remove-Item -Recurse -Force $leftover
                Write-Ok "Удалены остатки PyQt6-Qt6 с PyPI: $leftover"
            }
        }

        # Дымовой тест: импорт модулей
        $test = @'
from PyQt6 import QtCore, QtMultimedia, QtMultimediaWidgets
from PyQt6 import QtWebEngineCore, QtWebEngineWidgets
print("PyQt", QtCore.PYQT_VERSION_STR, "/ Qt", QtCore.QT_VERSION_STR)
'@
        $testFile = Join-Path $DevDir 'pyqt\import_test.py'
        Set-Content -Path $testFile -Value $test -Encoding ASCII
        & $BuildPy $testFile
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Импорт QtMultimedia и QtWebEngine из PyQt6 работает' }
        else { throw 'Импорт PyQt6-модулей не удался - смотрите лог выше.' }

        if ($AddQtToPath) {
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (($userPath -split ';') -notcontains $qtBin) {
                [Environment]::SetEnvironmentVariable('Path', "$qtBin;$userPath", 'User')
                Write-Ok "$qtBin добавлен в PATH пользователя (действует в новых окнах)"
            }
        }
        else {
            Write-Info "Чтобы PyQt6 находил Qt, в PATH должен быть $qtBin (или запустите скрипт с -AddQtToPath)."
        }
    }

    # -----------------------------------------------------------------------
    # 10. Переносимый комплект: колесо с Qt runtime + установщик
    # -----------------------------------------------------------------------
    if (-not $SkipPyQt) {
        Write-Step "Комплект -> $BundleDir"
        Invoke-Native $BuildPy @((Join-Path $ScriptDir 'make-bundle.py'), '--qt', $InstallDir, '--wheels', $wheelsDir,
                                 '--out', $BundleDir, '--files', (Join-Path $ScriptDir 'bundle-files'))
        foreach ($pat in 'pyqt6-*.whl', 'pyqt6_webengine-*.whl', 'pyqt6_qt6_local-*.whl', 'install.ps1', 'check.py') {
            if (-not (Get-ChildItem $BundleDir -Filter $pat -ErrorAction SilentlyContinue)) { throw "В комплекте нет $pat" }
        }
        Write-Ok "Комплект готов: $BundleDir (его можно копировать на другие ПК)"

        # -------------------------------------------------------------------
        # 11. Установка в venv проекта + проверка .mp4
        # -------------------------------------------------------------------
        if ($Project) {
            Write-Step "Установка в проект: $ProjectVenv"
            New-Item -ItemType Directory -Force $Project | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $BundleDir 'install.ps1') -Venv $ProjectVenv -Python $Python -Yes
            switch ($LASTEXITCODE) {
                0       { Write-Ok "PyQt6 установлен в $ProjectVenv, .mp4 поддерживается" }
                2       { Write-Warn2 'Установлено, но проверка .mp4 не прошла - смотрите вывод выше'; $pyqtOk = $false }
                default { throw "Установка в $ProjectVenv не удалась (код $LASTEXITCODE)" }
            }

            # ---------------------------------------------------------------
            # 12. requirements.txt проекта
            # ---------------------------------------------------------------
            if ($doReq) {
                Write-Step 'requirements.txt'
                Update-Requirements $reqFile $BundleDir $Project
            }
        }
    }

    $sw.Stop()
    Write-Step 'Итог'
    Write-Info "Qt:          $InstallDir"
    if (-not $SkipPyQt) {
        Write-Info "Колёса:      $wheelsDir"
        Write-Info "Комплект:    $BundleDir"
        if ($Project) {
            Write-Info "venv:        $ProjectVenv  (активировать: $ProjectVenv\Scripts\Activate.ps1)"
            if ($doReq) { Write-Info "requirements: $reqFile" }
        }
    }
    if ($allOk -and $pyqtOk) { Write-Host "`nГотово за $([int]$sw.Elapsed.TotalMinutes) мин." -ForegroundColor Green }
    else        { Write-Host "`nГотово с предупреждениями - смотрите лог." -ForegroundColor Yellow }
}
catch {
    Write-Host "`nОШИБКА: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Лог: $LogFile" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "Лог: $LogFile"
Stop-Transcript | Out-Null
