# PyQt6 + Qt WebEngine with H.264/AAC (.mp4) — offline bundle for Windows

This folder installs **PyQt6 6.11 + PyQt6-WebEngine 6.11** on top of a **locally built Qt 6.11.1**
whose WebEngine has proprietary codecs enabled (H.264 / AAC, i.e. `.mp4` plays in the browser)
and which includes **Qt Multimedia** (Windows Media Foundation backend).

The official `PyQt6-Qt6` / `PyQt6-WebEngine-Qt6` wheels on PyPI are built **without** these codecs,
which is why this bundle exists.

It works on a **clean Windows 10/11 x64**: no Qt, no Visual Studio, no Visual C++ Redistributable,
no PATH changes and no admin rights are required.

---

## Contents

| File | Purpose |
|---|---|
| `install.cmd` | Double-click launcher for `install.ps1` (bypasses the PowerShell execution policy for this run only) |
| `install.ps1` | Installer: preflight checks → questions → installation → verification |
| `pyqt6-6.11.0-cp310-abi3-win_amd64.whl` | PyQt6 bindings (incl. QtMultimedia, QtMultimediaWidgets) |
| `pyqt6_webengine-6.11.0-cp310-abi3-win_amd64.whl` | PyQt6-WebEngine bindings |
| `pyqt6_qt6_local-6.11.1-py3-none-win_amd64.whl` | Qt runtime: DLLs, `QtWebEngineProcess.exe`, plugins, WebEngine resources/locales, QML, MSVC runtime DLLs. Installs into `site-packages\PyQt6\Qt6` — the same layout as the official `PyQt6-Qt6` wheel |
| `pyqt6_sip-13.13.0-cp3XX-*.whl` | sip runtime for Python 3.10–3.14 (offline install) |
| `python-3.12.10-amd64.exe` | *(optional)* python.org installer, used only if the PC has no suitable Python |
| `check.py` | Verifies that the bundled Qt is used and that `.mp4` is supported |

The bindings are `abi3` wheels: one file works for every CPython **3.10 or newer**, 64-bit.

---

## Quick start

1. Copy the whole folder to the target PC (for example into your project as `vendor\pyqt-bundle`).
2. Run:

   ```bat
   install.cmd
   ```

   or non-interactively:

   ```bat
   install.cmd -Venv C:\path\to\project\.venv -Yes
   ```

3. At the end you should see:

   ```
   QtMultimedia MP4 + H.264: True
   WebEngine canPlayType mp4: 'probably' (expected 'probably')
   OK: .mp4 is supported
   ```

---

## What the installer does

### 1. Preflight checks (nothing is changed yet)

| Check | Result if it fails |
|---|---|
| Windows 10 1809+ / 11, 64-bit | **FAIL** — cannot be fixed by the script; update Windows |
| All bundle files present | **FAIL** — copy the folder again |
| Media Foundation (`mfplat.dll`) | **WARN** — missing on Windows *N* editions; Qt Multimedia cannot play video |
| Graphics adapter | **WARN** — VM / RDP / basic display driver; WebEngine may render a blank window |
| Python 3.10+ 64-bit | **WARN** — will be installed for the current user |
| Python installer in the folder | INFO — downloaded from python.org only if needed |
| Internet (pypi.org) | WARN — fine if everything needed is in the folder |
| Free disk space | WARN if < 1–1.5 GB |

Files are also unblocked (`Unblock-File`) in case they carry the "downloaded from the internet" mark.

### 2. Questions — only about what the script cannot decide or install by itself

| Question | When it is asked | Why it cannot be automatic |
|---|---|---|
| Path to the project venv | always (unless `-Venv`) | your project layout |
| Which Python to use / install Python 3.12.10 per-user | if several / none are found | your choice; installing software |
| Proxy URL | only if something must be downloaded and there is no internet | corporate network settings |
| Install **Media Feature Pack** now? | only on Windows *N* editions | needs admin rights (UAC) and a **reboot** |
| Enable software rendering for WebEngine? | only on VM / RDP / no GPU driver | real GPU drivers must be installed manually |
| Start? | always — shows the plan first | — |

### 3. Installation

1. Installs Python for the current user if requested (`InstallAllUsers=0`, no admin).
2. Creates the venv (or uses an existing one).
3. Removes `PyQt6`, `PyQt6-Qt6`, `PyQt6-WebEngine`, `PyQt6-WebEngine-Qt6` from PyPI if present
   (they bring their own Qt without codecs).
4. Installs the wheels from this folder with `--no-index` (offline).
   `PyQt6-sip` comes from the folder, or from PyPI if there is no wheel for that Python version.
5. Optional: writes `pyqt_local_softgl.pth` into the venv
   (`QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu`), and installs Media Feature Pack via UAC.
6. Runs `check.py`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Venv <path>` | asked | venv to create or reuse |
| `-Python <path>` | auto | use this `python.exe` to create the venv |
| `-Proxy <url>` | none | HTTP(S) proxy for downloads |
| `-PythonVersion 3.12.10` | `3.12.10` | Python to install if none is found |
| `-Yes` | off | accept all defaults, no questions |
| `-SkipCheck` | off | do not run `check.py` |

---

## Offline installation

Everything except Python itself is in the folder. On a PC **without internet and without Python**,
put `python-3.12.10-amd64.exe` (from <https://www.python.org/downloads/windows/>) into the folder first.

`PyQt6-sip` wheels are included for Python 3.10–3.14. For another version, add
`pyqt6_sip-*-cpXY-cpXY-win_amd64.whl` from <https://pypi.org/project/PyQt6-sip/#files>.

---

## Using it in a project

### requirements.txt

Reference the wheels **by file path**, not by package name:

```text
vendor/pyqt-bundle/pyqt6-6.11.0-cp310-abi3-win_amd64.whl
vendor/pyqt-bundle/pyqt6_webengine-6.11.0-cp310-abi3-win_amd64.whl
vendor/pyqt-bundle/pyqt6_qt6_local-6.11.1-py3-none-win_amd64.whl
PyQt6-sip>=13.13,<14
```

Run `pip install -r requirements.txt` from the project root (paths are relative to the current directory).

> **Do not** write `PyQt6==6.11.0`, `PyQt6-WebEngine==...` or `PyQt6-Qt6` in requirements:
> pip will take them from PyPI and you get Qt **without** H.264/AAC.
> The same applies to other packages that depend on `PyQt6` by name — install them with `--no-deps`
> or after this bundle.

### Git

The Qt runtime wheel is ~150 MB. If the bundle is committed, track `*.whl` and `*.exe`
with Git LFS:

```bash
git lfs track "vendor/pyqt-bundle/*.whl" "vendor/pyqt-bundle/*.exe"
```

### Code

Nothing special is needed — no `os.add_dll_directory`, no PATH:

```python
from PyQt6.QtWidgets import QApplication
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtMultimedia import QMediaPlayer
```

### Packaging the application (PyInstaller etc.)

The Qt runtime lives in `site-packages\PyQt6\Qt6`, exactly like the official PyPI wheels,
so tools that support PyQt6 from PyPI (e.g. PyInstaller's PyQt6 hooks) find Qt, plugins,
`QtWebEngineProcess.exe` and WebEngine resources the same way.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Could not find the Qt platform plugin "windows"` | Another Qt is used. Run `python -c "from PyQt6.QtCore import QLibraryInfo as L; print(L.path(L.LibraryPath.PrefixPath))"` — it must end with `site-packages/PyQt6/Qt6`. Re-run `install.cmd` with the same venv. |
| `canPlayType` returns `''` | PyPI Qt was installed over the bundle (e.g. by `pip install -r` with `PyQt6==...`). Check `pip list` for `PyQt6-Qt6` / `PyQt6-WebEngine-Qt6`, then re-run `install.cmd`. |
| `QtMultimedia MP4 + H.264: False` | Media Foundation missing (Windows *N*): install Media Feature Pack and reboot. |
| WebEngine window is blank / black | VM, RDP or no GPU driver: install the GPU driver, or re-run the installer and accept software rendering (`QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu`). |
| `ImportError: DLL load failed` | Incomplete install, or a 32-bit Python. Use 64-bit Python 3.10+ and re-run `install.cmd`. |
| `PyQt6-sip install failed` | No sip wheel for this Python in the folder and no internet: add the wheel (see *Offline installation*) or use `-Proxy`. |
| Script is blocked by execution policy | Start it via `install.cmd`, or `powershell -ExecutionPolicy Bypass -File install.ps1`. |

---

## Licensing

PyQt6 is used under the **GPL v3**; Qt is used under **LGPL v3 / GPL**. H.264 and AAC are patent-encumbered
formats — check whether you need a license before distributing an application that decodes them.
