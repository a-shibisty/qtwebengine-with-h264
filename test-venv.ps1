# Creates a clean venv C:\dev\venv-test, installs locally built PyQt6 + PyQt6-WebEngine
# from C:\dev\wheels and runs test-mp4.py in it.
param(
    [string]$Python = 'python',
    [string]$Venv   = 'C:\dev\venv-test',
    [switch]$Recreate,
    [switch]$Debug
)
$ErrorActionPreference = 'Stop'
$wheels = 'C:\dev\wheels'
$qtBin  = 'C:\qt6install\bin'

function Run([string]$exe, [string[]]$a) {
    Write-Host "> $exe $($a -join ' ')" -ForegroundColor DarkGray
    & $exe @a
    if ($LASTEXITCODE -ne 0) { throw "exit code ${LASTEXITCODE}: $exe" }
}

if ($Recreate -and (Test-Path $Venv)) { Remove-Item -Recurse -Force $Venv }
if (-not (Test-Path "$Venv\Scripts\python.exe")) { Run $Python @('-m', 'venv', $Venv) }
$py = "$Venv\Scripts\python.exe"

$pyqt = Get-ChildItem $wheels -Filter 'pyqt6-*.whl'           | Sort-Object LastWriteTime | Select-Object -Last 1
$web  = Get-ChildItem $wheels -Filter 'pyqt6_webengine-*.whl' | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $pyqt -or -not $web) { throw "No wheels in $wheels" }

Run $py @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--upgrade', 'pip', 'PyQt6-sip')
Run $py @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check', '--force-reinstall', '--no-deps', $pyqt.FullName, $web.FullName)

# There must be no PyQt6\Qt6 folder in the venv, otherwise Qt is looked up there
$leftover = "$Venv\Lib\site-packages\PyQt6\Qt6"
if (Test-Path $leftover) { Remove-Item -Recurse -Force $leftover; Write-Host "Removed $leftover" }

Write-Host "`nInstalled packages:" -ForegroundColor Cyan
& $py -m pip list --disable-pip-version-check | Select-String -Pattern 'PyQt'

# Qt DLLs for this run (in case PATH was not updated yet)
$env:Path = "$qtBin;$env:Path"

Write-Host "`n=== test-mp4.py ===" -ForegroundColor Cyan
$a = @('C:\dev\test-mp4.py'); if ($Debug) { $a += '--debug' }
& $py @a
Write-Host "`nActivate this venv: $Venv\Scripts\Activate.ps1"
