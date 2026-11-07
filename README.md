# Qt 6 WebEngine with H.264/AAC + Qt Multimedia + PyQt6 — built and installed into your project by one script

`build-qt.ps1` takes a **clean Windows 10/11 x64** machine all the way to a Python project that plays `.mp4` in `QWebEngineView`:

1. **Preflight and questions.** Shows an OK / WARN / FAIL table and asks only about what cannot be decided or installed automatically. Nothing is changed until you answer "Start?".
2. **Environment:** VS 2022 Build Tools (C++), Git, CMake, Ninja, Python, Node.js, Perl (via winget), bison and gperf, plus a separate build venv. MinGW, MSYS2 and Strawberry `c\bin` are removed from `PATH` for the duration of the build.
3. **Sources:** `git clone qt5.git` at the requested tag and `git submodule update`, including Chromium.
4. **CMake configure** with `-webengine-proprietary-codecs`. The script verifies `Proprietary Codecs: yes` in `config.summary`.
5. **Build and install** Qt WebEngine and Qt Multimedia into `C:\qt6install`.
6. **Component check:** DLLs, `QtWebEngineProcess.exe`, plugins, WebEngine resources and locales, and the presence of the proprietary-codec code in `Qt6WebEngineCore.dll`.
7. **Wheels:** PyQt6 and PyQt6-WebEngine built from source (`sip-wheel`). The script verifies that QtGui, QtWidgets, QtMultimedia and WebEngine are inside.
8. **Portable bundle** (`make-bundle.py`): a `pyqt6_qt6_local` wheel containing the Qt runtime and the MSVC runtime, plus the `install.cmd` installer and an English README.
9. **Install into the project venv** and verify `.mp4` support (`canPlayType` → `'probably'`).
10. **Project `requirements.txt`:** `PyQt6==...` and `PyQt6-Qt6` lines are replaced with paths to the local wheels; the old file is kept as `.bak`.

Your main Python installation is never modified: wheels go only into the build venv and the project venv.

## What you need on a clean PC

Clone the repository (`git clone https://github.com/a-shibisty/qtwebengine-with-h264.git C:\dev`) or copy the toolkit folder. The required files are:

```
C:\dev\
  build.cmd          <- run this
  build-qt.ps1
  make-bundle.py
  bundle-files\      install.ps1, install.cmd, check.py, README.md (copied into the bundle)
  README.md
```

`make-bundle.py` and `bundle-files\` must stay next to `build-qt.ps1`.

## Running

```bat
build.cmd
```
Interactive: preflight, questions, plan, then the whole chain.

```bat
build.cmd -Project C:\work\myapp -QtVersion 6.11.1 -Yes
```
No questions, defaults everywhere.

```bat
build.cmd -CheckOnly
```
Preflight table only; nothing is changed.

`build.cmd` runs `build-qt.ps1` with `-ExecutionPolicy Bypass` for this run only. Run it from a **normal** console, not a Developer PowerShell: the script sets up the MSVC environment itself.

### Preflight checks

| Check | Result | Why the script cannot fix it |
|---|---|---|
| Windows 10 1809+ / 11, x64 | FAIL | Windows must be updated |
| Toolkit files next to the script | FAIL | copy or clone the whole folder |
| Free disk space (Full: ~100 GB, minimum 60) | FAIL / WARN | only you can free space |
| RAM (Full: minimum 8 GB, 16–32 recommended) | FAIL / WARN | hardware |
| winget (when tools need to be installed) | FAIL | install "App Installer" from the Microsoft Store manually |
| Access to code.qt.io, github.com, pypi.org | FAIL → proxy question | network settings |
| Windows long paths | WARN → question | needs admin rights (UAC) |
| Media Foundation | WARN | Windows "N" editions: install "Media Feature Pack" manually |
| Microsoft Store Python | WARN | works, but python.org Python is more reliable |

The table also shows what is already present (Qt sources, Qt WebEngine with or without codecs, Qt Multimedia) and the build mode that will be used.

### Questions

| Question | Asked when |
|---|---|
| Qt version for `git clone` (default 6.11.1) | there are no sources |
| Project folder, venv, bundle location | always, unless `-Project` is given (`-` = do not install into a project) |
| Update or create `requirements.txt` | a project is given |
| Multimedia backend: FFmpeg (default) or Media Foundation | Qt Multimedia is going to be built |
| Enable long paths (UAC) | full build and long paths are off |
| Add the build folders to Defender exclusions (UAC) | full build; makes it several times faster |
| Install VS 2022 Build Tools (~10 GB, UAC) | MSVC is not found |
| "Start?" with the plan and a time estimate | always |

All admin actions (long paths, Defender) are done with a single UAC prompt. If it is declined, the script continues without them.

### Modes (chosen automatically)

| Mode | When | What is built | Time |
|---|---|---|---|
| `Full` | no Qt WebEngine with codecs in `C:\qt6install` | qtwebengine + qtmultimedia + qtsvg + qttools | 4–10 h |
| `AddMultimedia` | WebEngine with codecs is installed, Multimedia is not | qtshadertools (if `qsb.exe` is missing) + qtmultimedia | ~1–1.5 h including PyQt |
| `PyQtOnly` | Qt is complete | PyQt6 + PyQt6-WebEngine wheels only | 40–70 min; minutes if the wheels already exist |

Whether WebEngine has proprietary codecs is taken from `C:\qt6build\config.summary`. If that file is missing, the script looks inside `Qt6WebEngineCore.dll` for the Chromium MP4 parser (`media/formats/mp4/mp4_stream_parser`), which is compiled only with `proprietary_codecs`. A WebEngine that already has codecs is **never** rebuilt in `Auto` mode.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Project <folder>` | asked | project to install PyQt6 into (`-` = none) |
| `-ProjectVenv <path>` | `<Project>\.venv` | project venv |
| `-BundleDir <path>` | `<Project>\vendor\pyqt-bundle`, or `C:\dev\pyqt-bundle` without a project | where the portable bundle goes |
| `-NoRequirements` | off | do not touch `requirements.txt` |
| `-Proxy <url>` | none | proxy for git, pip and downloads |
| `-Yes` | off | no questions, use defaults |
| `-CheckOnly` | off | preflight only |
| `-Mode Auto\|Full\|AddMultimedia\|PyQtOnly` | `Auto` | force a build mode |
| `-QtVersion 6.11.1` | asked | Qt tag to clone (only when there are no sources) |
| `-UseFFmpeg` | asked | FFmpeg backend for Qt Multimedia |
| `-FFmpegUrl <url>` | auto | your own zip with a shared FFmpeg build |
| `-SrcDir` / `-BuildDir` / `-InstallDir` / `-DevDir` | `C:\qt6src`, `C:\qt6build`, `C:\qt6install`, `C:\dev` | folders |
| `-Jobs N` | auto (min of CPU threads and RAM / 2 GB) | parallel jobs |
| `-Clean` | off | delete build folders before configuring |
| `-SkipPrereqInstall` | off | do not install tools, only check |
| `-Python <path>` | `python` from `PATH` | 64-bit Python 3.10+ used for the build venv and the project venv |
| `-SkipPyQt` | off | build Qt only, no wheels, bundle or project install |
| `-PyQtVersion` / `-PyQtWebEngineVersion` | latest with Qt's major.minor | pin binding versions |
| `-AddQtToPath` | off | add `C:\qt6install\bin` to the user `PATH` (only needed to use the build PC's Qt directly, not for the bundle) |

Every run is logged to `C:\dev\logs\build-qt-<date>.log`.

---

## 1. Manual preparation (only what the script cannot do)

### 1.1. winget
Needed to install tools. Check with `winget --version`. If the command is missing, install **App Installer** from the Microsoft Store.

### 1.2. Long paths (recommended, admin rights)
Chromium has very deep paths. The script offers to enable this via UAC. To do it manually, run in an **elevated** PowerShell:
```powershell
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force
```
Then restart the PC.

### 1.3. Microsoft Store Python
The Store `python` alias either opens the Store or gives a sandboxed Python. It works, but python.org Python is more reliable. Install it from <https://www.python.org/downloads/windows/> (64-bit, tick "Add python.exe to PATH") or with `winget install Python.Python.3.12`, then pass its path: `-Python C:\Users\<you>\AppData\Local\Programs\Python\Python312\python.exe`. To get rid of the Store stub, turn off `python.exe` and `python3.exe` in **Settings → Apps → Advanced app settings → App execution aliases**.

### 1.4. Visual Studio 2022 (if you prefer to install it yourself)
The script installs **VS 2022 Build Tools** if MSVC is not found. If Visual Studio is already installed, make sure the Visual Studio Installer has:
- the **"Desktop development with C++"** workload;
- **MSVC v143 x64/x86**;
- **Windows 11 SDK** (10.0.22621 or newer).

### 1.5. MinGW / MSYS2 / Strawberry in PATH
If `PATH` contains `C:\msys64\...`, `C:\Strawberry\c\bin` or another MinGW, CMake may pick `cmake`, `gcc` or libraries from there and produce a "mixed" Qt. The script removes these entries from `PATH` while it runs (Perl from `C:\Strawberry\perl\bin` stays) and sets `CMAKE_IGNORE_PREFIX_PATH`. Do the same if you build anything by hand.

### 1.6. Resources
- **Disk:** ~100 GB free for a full WebEngine build; ~15 GB for Multimedia + PyQt.
- **RAM:** 16 GB or more, 32 GB recommended. The script limits parallel jobs to "RAM / 2 GB".
- **Antivirus:** excluding `C:\qt6src`, `C:\qt6build`, `C:\qt6install` and `C:\dev` from Defender speeds the build up a lot. The script offers to do this via UAC.

---

## 2. What the script does, in detail

1. Preflight and questions (see above).
2. Installs missing tools:
   - via winget: Git, CMake, Ninja, Node.js LTS, Strawberry Perl, Python 3.12, VS 2022 Build Tools;
   - downloads **win_flex_bison** (GitHub) and **gperf** (GnuWin32, SourceForge) into `C:\dev\tools`;
   - creates the build venv `C:\dev\venv-build` with `html5lib`, `sip`, `PyQt-builder` and `PyQt6-sip`.
3. Enters the MSVC x64 environment (the equivalent of the *x64 Native Tools Command Prompt*).
4. Prepares the sources:
   - if `C:\qt6src` is empty, clones `qt5.git` at `v<QtVersion>`;
   - initializes only the submodules that are missing; Chromium is fetched only for a full build;
   - checks that every required module, and Chromium for a full build, is present.
5. With FFmpeg selected, downloads a shared LGPL FFmpeg build from BtbN into `C:\dev\ffmpeg`. The current file name is taken from the GitHub API of the latest release. Version 7.1 is preferred for Qt 6.8+ (the one Qt 6.11 is built against) and 6.1 for older Qt. If that version is missing, the closest available one is used, with a warning.
6. Builds and installs Qt into `C:\qt6install` according to the mode.
7. Checks the result and stops if anything is missing: `Qt6WebEngineCore.dll`, `Qt6WebEngineWidgets.dll`, `QtWebEngineProcess.exe`, `Qt6Multimedia.dll`, `Qt6MultimediaWidgets.dll`, `plugins\multimedia\*`, `plugins\platforms\qwindows.dll`, WebEngine resources and locales, and the codec marker in `Qt6WebEngineCore.dll`.
8. Builds the PyQt bindings (about 30–60 minutes):
   - removes leftover MinGW settings from `C:\qt6install\mkspecs\modules\*.pri` (`-lmingw32`, `QT_NEEDS_QMAIN`), keeping `.bak` copies;
   - downloads the **PyQt6** and **PyQt6-WebEngine** source distributions from PyPI, using the latest release with Qt's major.minor (for Qt 6.11.x that is PyQt6 6.11.*);
   - builds wheels with `sip-wheel --qmake C:\qt6install\bin\qmake.exe` into `C:\dev\wheels`, and fails if a required module is missing from a wheel;
   - reuses an existing complete wheel of the same version instead of rebuilding it (unless `-Clean`);
   - runs an import test of `QtMultimedia`, `QtMultimediaWidgets`, `QtWebEngineCore` and `QtWebEngineWidgets` in the build venv.
9. Builds the portable bundle with `make-bundle.py`.
10. Runs `<bundle>\install.ps1 -Yes` for the project venv. That removes PyPI PyQt6 from the venv, installs the three wheels and runs `check.py`.
11. Updates `requirements.txt`. The result is the same on every run.

The script is safe to re-run: installed tools, downloaded archives, sources and finished wheels are skipped.

---

## 3. Multimedia backend

- **FFmpeg** (default answer, `-UseFFmpeg`). This is the main Qt Multimedia backend: more formats and the same behaviour on every platform. Qt 6.11 is built against FFmpeg 7.1. The FFmpeg DLLs are copied into `C:\qt6install\bin` and therefore end up in the bundle. The build is LGPL, so follow the LGPL when you distribute it.
- **Windows Media Foundation.** Nothing extra is needed: `.mp4` (H.264/AAC) is played by Windows' own codecs. This backend is deprecated since Qt 6.10, and it is unavailable on Windows "N" editions without the Media Feature Pack.

The `.mp4` support in **WebEngine** does not depend on this choice. It comes from Chromium's proprietary codecs.

---

## 4. Using the result

### Python project (recommended way)

After a run with `-Project`, the project has:
- `.venv` with PyQt6, PyQt6-WebEngine and PyQt6-Qt6-Local (Qt inside `site-packages\PyQt6\Qt6`; no `PATH` changes needed);
- `vendor\pyqt-bundle\` with the wheels and the installer;
- `requirements.txt` that references the wheels by path:

```text
vendor/pyqt-bundle/pyqt6-6.11.0-cp310-abi3-win_amd64.whl
vendor/pyqt-bundle/pyqt6_webengine-6.11.0-cp310-abi3-win_amd64.whl
vendor/pyqt-bundle/pyqt6_qt6_local-6.11.1-py3-none-win_amd64.whl
PyQt6-sip>=13.13,<14
```

Run `pip install -r requirements.txt` from the project root. **Do not** list `PyQt6`, `PyQt6-WebEngine` or `PyQt6-Qt6` by name: pip would take them from PyPI, whose Qt has no H.264/AAC.

The Qt runtime wheel is about 150 MB. If you commit `vendor\pyqt-bundle`, use Git LFS for `*.whl` and `*.exe`.

On other PCs you only need the bundle: copy `vendor\pyqt-bundle` and run `install.cmd`. See `bundle-files\README.md`: no Qt build, no Visual Studio and no admin rights are needed there.

### Test helpers on the build PC

- `test-venv.ps1` creates `C:\dev\venv-test` from `C:\dev\wheels` and runs `test-mp4.py`.
- `test-mp4.py` prints which `Qt6Core.dll` is loaded, the Qt prefix, the plugin path and the `.mp4` support. Pass `--debug` for Qt plugin logs.

These helpers use the Qt in `C:\qt6install` directly, so `C:\qt6install\bin` must be in `PATH` (`-AddQtToPath`).

### C++ (CMake / qmake)

CMake:
```cmake
set(CMAKE_PREFIX_PATH "C:/qt6install")
find_package(Qt6 REQUIRED COMPONENTS WebEngineWidgets Multimedia MultimediaWidgets)
target_link_libraries(app PRIVATE Qt6::WebEngineWidgets Qt6::Multimedia Qt6::MultimediaWidgets)
```

qmake:
```
QT += webenginewidgets multimedia multimediawidgets
```

Deployment:
```
C:\qt6install\bin\windeployqt.exe --release path\to\app.exe
```

---

## 5. Troubleshooting

| Symptom | What to do |
|---|---|
| `Proprietary codecs were not enabled` | Codec support was not enabled in WebEngine. Check `C:\qt6build\config.summary` and the configure log. |
| `path too long` / `filename longer than 260` errors | Enable long paths (1.2) and restart. |
| `fatal error C1060: out of heap space`, linker hangs | Reduce parallelism, e.g. `-Jobs 4`. |
| FFmpeg download fails | The file is found through the GitHub API of BtbN/FFmpeg-Builds. If the API is unavailable (rate limit, proxy), pass `-FFmpegUrl <...-win64-lgpl-shared-...zip>` or unpack FFmpeg into `C:\dev\ffmpeg` (with `include`, `lib`, `bin`). |
| gperf download fails (SourceForge) | Download `gperf-3.0.1-bin.zip` from <https://gnuwin32.sourceforge.net/packages/gperf.htm> and unpack it into `C:\dev\tools\gperf`, so that `C:\dev\tools\gperf\bin\gperf.exe` exists. |
| `python` opens the Microsoft Store | See 1.3. |
| "command not found" right after tools were installed | Close the console, open a new one and run again. Finished steps are skipped. |
| Need to start from scratch | Run with `-Clean`. |
| `Full` mode chosen although WebEngine is already built with codecs | Run `build.cmd -CheckOnly` and look at the "Qt WebEngine" line. To force a mode, pass `-Mode AddMultimedia` or `-Mode PyQtOnly`. |
| `QtGui/QtGuimod.sip could not be found` while building PyQt6-WebEngine, or PyQt6 has no QtGui/QtWidgets | `qt_lib_entrypoint_private.pri` still has `DEFINES = QT_NEEDS_QMAIN` from MinGW. It renames `main` to `qMain`, so linking the GUI config tests fails with `LNK2019: unresolved external symbol main`. The script removes the macro and verifies the wheel contents. |
| `sip-wheel: There are no bindings that can be built` | `C:\qt6install\mkspecs\modules\*.pri` contains `-lmingw32` because MinGW was in `PATH` during an earlier build. qmake then adds `mingw32.lib` and MSVC linking fails. The script removes the flag, keeping a `.bak` copy. |
| The log shows `cmake` from `C:\Strawberry\c\bin` or `C:\msys64\...` paths | These are MinGW tools and break an MSVC build. The script removes them from `PATH` and sets `CMAKE_IGNORE_PREFIX_PATH`. Do the same for manual builds. |
| `There is no Qt Multimedia in C:\qt6install` | Build Multimedia first (`-Mode AddMultimedia`), then PyQt. |
| `Could not find the Qt platform plugin "windows"` | A `site-packages\PyQt6\Qt6` folder from another Qt is used. In a project venv it must be the one from `PyQt6-Qt6-Local`: `python -c "from PyQt6.QtCore import QLibraryInfo as L; print(L.path(L.LibraryPath.PrefixPath))"` should print `.../site-packages/PyQt6/Qt6`. Re-run the bundle's `install.cmd` for that venv. |
| `ImportError: DLL load failed` on `from PyQt6 import ...` | In a project venv, the bundle was installed incompletely: re-run `install.cmd`. With the build venv or `venv-test`, `C:\qt6install\bin` is not in `PATH`. |
| `64-bit Python 3.10+ is required` | Install 64-bit CPython 3.10+ and pass it with `-Python`. |
| `PyQt6 for Qt X.Y not found` | Qt is newer than the latest PyQt6 on PyPI. The script takes the closest older version, so some of the newest Qt APIs will be missing in Python. |
| Compilation error in sip-wheel | PyQt6 and Qt versions are too far apart. Pin them with `-PyQtVersion` / `-PyQtWebEngineVersion`. |
| `.mp4` still does not play in PyQt6 WebEngine | Check which Qt is loaded (see the platform plugin row) and run `python vendor\pyqt-bundle\check.py` in the project venv. |

---

## Licensing

PyQt6 is GPL v3. Qt is LGPL v3 / GPL. FFmpeg builds used here are LGPL. H.264 and AAC are patent-encumbered formats: check whether you need a license before distributing an application that decodes them. `widevinecdm.dll` is Google's proprietary binary and must not be committed or redistributed.
