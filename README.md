# Сборка Qt 6 WebEngine (H.264/AAC) + Multimedia + PyQt6 и установка в проект — одним скриптом

Набор `qt-build-kit` проходит весь путь на **чистой Windows 10/11 x64**:

1. **Проверка и вопросы.** Скрипт показывает таблицу OK / WARN / FAIL и спрашивает только то, что нельзя решить автоматически. Ничего не меняется до ответа «Начать?».
2. **Окружение:** VS 2022 Build Tools (C++), Git, CMake, Ninja, Python, Node.js, Perl, bison, gperf. Ставит их через winget, отдельный venv для сборки. Из PATH убираются MinGW, MSYS и Strawberry `c\bin`.
3. **Исходники:** `git clone qt5.git` нужной версии и `git submodule update`, включая Chromium.
4. **CMake configure** с `-webengine-proprietary-codecs`. Скрипт проверяет `Proprietary Codecs: yes` в `config.summary`.
5. **Сборка и установка** Qt WebEngine и Qt Multimedia в `C:\qt6install`.
6. **Проверка компонентов:** DLL, `QtWebEngineProcess.exe`, плагины, ресурсы и локали WebEngine, H.264-декодер в `Qt6WebEngineCore.dll`.
7. **Колёса** PyQt6 и PyQt6-WebEngine из исходников (sip-wheel) с проверкой, что внутри есть QtGui, QtWidgets, QtMultimedia и WebEngine.
8. **Переносимый комплект** (`make-bundle.py`): колесо `pyqt6_qt6_local` с Qt runtime и рантаймом MSVC, установщик `install.cmd` и README на английском.
9. **Установка в venv проекта** и проверка `.mp4` (`canPlayType` → `'probably'`).
10. **`requirements.txt` проекта:** `PyQt6==...` и `PyQt6-Qt6` заменяются путями к колёсам, копия сохраняется в `.bak`.

## Что нужно на чистом ПК

Склонируйте репозиторий (`git clone https://github.com/a-shibisty/qtwebengine-with-h264.git C:\dev`) или скопируйте папку `C:\dev\qt-build-kit` целиком. Нужны файлы:

```
qt-build-kit\
  build.cmd          <- запускать его
  build-qt.ps1
  make-bundle.py
  bundle-files\      (install.ps1, install.cmd, check.py, README.md - попадут в комплект)
  README.md
```

## Запуск

```bat
build.cmd
```
Это интерактивный режим: проверка, вопросы, план, затем вся цепочка.

```bat
build.cmd -Project C:\work\myapp -QtVersion 6.11.1 -Yes
```
Без вопросов, со значениями по умолчанию.

```bat
build.cmd -CheckOnly
```
Только таблица проверок, ничего не меняется.

### Что проверяется в начале

| Проверка | FAIL / WARN | Почему скрипт не исправит сам |
|---|---|---|
| Windows 10 1809+ / 11, x64 | FAIL | нужно обновить Windows |
| Файлы набора рядом со скриптом | FAIL | скопируйте папку целиком |
| Свободное место (Full: ~100 ГБ, минимум 60) | FAIL / WARN | освободить место можете только вы |
| RAM (Full: минимум 8 ГБ, лучше 16–32) | FAIL / WARN | железо |
| winget (если нужно ставить инструменты) | FAIL | ставится вручную: «App Installer» из Microsoft Store |
| Доступ к code.qt.io, github.com, pypi.org | FAIL → вопрос о прокси | сетевые настройки |
| Длинные пути Windows | WARN → вопрос | нужны права администратора (UAC) |
| Media Foundation | WARN | Windows N: «Media Feature Pack» ставится вручную |
| Python из Microsoft Store | WARN | работает, но надёжнее python.org |

### Вопросы

| Вопрос | Когда задаётся |
|---|---|
| Версия Qt для `git clone` (по умолчанию 6.11.1) | если исходников нет |
| Папка проекта, venv, куда положить комплект | всегда, если не задано `-Project` (`-` = не ставить в проект) |
| Обновить или создать `requirements.txt` | если указан проект |
| Бэкенд Multimedia: FFmpeg или Media Foundation | при сборке Qt |
| Включить длинные пути (UAC) | при полной сборке, если они выключены |
| Исключения Defender для папок сборки (UAC) | при полной сборке; ускоряет сборку в разы |
| Поставить VS 2022 Build Tools (~10 ГБ, UAC) | если MSVC нет |
| «Начать?» с планом и оценкой времени | всегда |

### Режимы (выбираются автоматически)

| Режим | Когда | Время |
|---|---|---|
| `Full` | нет Qt WebEngine с кодеками | 4–10 ч |
| `AddMultimedia` | WebEngine с кодеками есть, Multimedia нет | ~1–1.5 ч (с PyQt) |
| `PyQtOnly` | Qt полностью готов | 40–70 мин; минуты, если колёса уже собраны |

### Новые параметры

| Параметр | Описание |
|---|---|
| `-Project <папка>` | куда поставить PyQt6 (`-` = не ставить) |
| `-ProjectVenv <путь>` | venv проекта (по умолчанию `<Project>\.venv`) |
| `-BundleDir <путь>` | куда положить комплект (по умолчанию `<Project>\vendor\pyqt-bundle`) |
| `-NoRequirements` | не трогать `requirements.txt` |
| `-Proxy <url>` | прокси для git, pip и загрузок |
| `-Yes` | без вопросов |

Ниже — подробности по ручной подготовке и параметрам сборки.

---

## 1. Что сделать вручную перед первым запуском

Большую часть зависимостей скрипт ставит сам. Следующее через PowerShell не делается или требует прав администратора.

### 1.1. winget
Он нужен скрипту для установки инструментов. Проверьте командой `winget --version`. Если команды нет, установите **App Installer** из Microsoft Store.

### 1.2. Длинные пути (рекомендуется, нужны права администратора)
В Chromium очень глубокие пути. Откройте PowerShell **от имени администратора** и выполните:
```powershell
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name LongPathsEnabled -Value 1 -PropertyType DWORD -Force
```
После этого перезагрузите компьютер.

### 1.3. Отключите заглушки python из Microsoft Store
Откройте **Параметры → Приложения → Дополнительные параметры → Псевдонимы выполнения приложений** и выключите `python.exe` и `python3.exe`. Иначе вместо Python будет открываться Store.

### 1.3а. Python с python.org (рекомендуется)
Python из Microsoft Store (путь вида `...\WindowsApps\PythonSoftwareFoundation.Python.3.12_...`) работает, но устроен в «песочнице», и с ним бывают проблемы при сборке. Надёжнее поставить Python с https://www.python.org/downloads/windows/ (64-bit, с галкой «Add python.exe to PATH») или через `winget install Python.Python.3.12`, а затем передать путь скрипту: `-Python C:\Users\<вы>\AppData\Local\Programs\Python\Python312\python.exe`.

### 1.4. Visual Studio 2022 (если хотите поставить сами)
Скрипт сам поставит **VS 2022 Build Tools**, если не найдёт MSVC. Если VS уже установлена, проверьте в Visual Studio Installer, что отмечены:
- нагрузка **«Разработка классических приложений на C++»**;
- **MSVC v143 x64/x86**;
- **Windows 11 SDK** (10.0.22621 или новее).

### 1.4а. MinGW / MSYS2 / Strawberry в PATH
Если в PATH есть `C:\msys64\...`, `C:\Strawberry\c\bin` или другой MinGW, CMake может взять оттуда `cmake`, `gcc` или библиотеки, и Qt соберётся «смешанным». Скрипт на время своей работы убирает эти пути из PATH (Perl из `C:\Strawberry\perl\bin` остаётся), но при ручной сборке за этим нужно следить самому.

### 1.5. Ресурсы
- **Место:** около 100 ГБ свободного места для полной сборки WebEngine, для дособорки Multimedia — около 5 ГБ.
- **Память:** от 16 ГБ RAM, лучше 32 ГБ. Скрипт сам ограничивает число параллельных задач значением «RAM / 2 ГБ».
- **Антивирус:** добавьте `C:\qt6src`, `C:\qt6build` и `C:\qt6install` в исключения Defender. Это заметно ускоряет сборку.

---

## 2. Что скрипт делает сам

1. Проверяет длинные пути, свободное место, CPU и RAM.
2. Ставит недостающие инструменты:
   - через winget: Git, CMake, Ninja, Node.js LTS, Strawberry Perl, Python 3.12, VS 2022 Build Tools;
   - создаёт отдельный venv `C:\dev\venv-build` и ставит в него `html5lib`, `sip` и `PyQt-builder`. Ваш основной Python скрипт не трогает: туда попадают только готовые колёса PyQt6 и рантайм `PyQt6-sip`;
   - скачивает в `C:\dev\tools`: **win_flex_bison** (GitHub) и **gperf** (GnuWin32, SourceForge).
3. Входит в окружение MSVC x64 (аналог *x64 Native Tools Command Prompt*).
4. Готовит исходники:
   - если `C:\qt6src` пуст, клонирует `qt5.git` нужной версии;
   - если исходники уже есть, доинициализирует только недостающие модули (`qtmultimedia`, `qtshadertools` и т.д.), уже скачанные модули не трогает.
5. С ключом `-UseFFmpeg` скачивает shared-сборку FFmpeg (BtbN, LGPL) в `C:\dev\ffmpeg`. Версия выбирается по версии Qt: для 6.8+ — FFmpeg 7.1, для более старых — 6.1.
6. Выбирает режим сборки (см. ниже), собирает и устанавливает Qt в `C:\qt6install`.
7. Проверяет, что появились `Qt6WebEngineCore.dll`, `QtWebEngineProcess.exe`, `Qt6Multimedia.dll` и плагины в `plugins\multimedia`.
8. Собирает биндинги PyQt (около 30–60 минут):
   - удаляет из выбранного Python пакеты `PyQt6`, `PyQt6-Qt6`, `PyQt6-WebEngine` и `PyQt6-WebEngine-Qt6`, установленные с PyPI;
   - ставит `sip`, `PyQt-builder` и `PyQt6-sip`;
   - скачивает с PyPI исходники **PyQt6** и **PyQt6-WebEngine** последней версии с той же major.minor, что и Qt (для Qt 6.8.x — PyQt6 6.8.*);
   - собирает колёса через `sip-wheel --qmake C:\qt6install\bin\qmake.exe`, копирует их в `C:\dev\wheels` и устанавливает в Python;
   - для проверки импортирует `QtMultimedia`, `QtMultimediaWidgets`, `QtWebEngineCore` и `QtWebEngineWidgets`.

### Режимы сборки

| Режим | Когда | Что собирает | Время |
|---|---|---|---|
| `Auto` (по умолчанию) | — | выбирает режим сам по `C:\qt6install` и `C:\qt6build\config.summary` | — |
| `AddMultimedia` | WebEngine уже установлен **и** собран с `Proprietary Codecs: yes` | только qtshadertools (если нет `qsb.exe`) и qtmultimedia | минуты |
| `Full` | всё остальное | qtwebengine + qtmultimedia + qtsvg + qttools с `-webengine-proprietary-codecs` | часы |
| `PyQtOnly` | Qt уже собран, нужны только биндинги | только PyQt6 и PyQt6-WebEngine | 30–60 мин |

PyQt собирается в любом режиме, кроме запуска с ключом `-SkipPyQt`.

Если в прошлый раз WebEngine собрался с кодеками, скрипт **не будет** пересобирать его заново.

---

## 3. Запуск

Положите `build-qt.ps1` в `C:\dev` и откройте **обычный** PowerShell (не Developer PowerShell, скрипт сам настроит окружение VS):

```powershell
cd C:\dev

# Сначала посмотреть, что найдено и что будет сделано, ничего не собирая:
powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -CheckOnly

# Сборка (бэкенд Multimedia: Windows Media Foundation):
powershell -ExecutionPolicy Bypass -File .\build-qt.ps1

# Сборка с FFmpeg-бэкендом Multimedia:
powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -UseFFmpeg

# Всё, плюс сразу прописать C:\qt6install\bin в PATH пользователя (нужно для PyQt6):
powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -AddQtToPath

# Только пересобрать PyQt под конкретный Python (например, для venv проекта):
powershell -ExecutionPolicy Bypass -File .\build-qt.ps1 -Mode PyQtOnly -Python C:\path\to\venv\Scripts\python.exe
```

Во время установки инструментов может появиться запрос UAC. Подтвердите его.

### Параметры

| Параметр | По умолчанию | Описание |
|---|---|---|
| `-SrcDir` / `-BuildDir` / `-InstallDir` / `-DevDir` | см. таблицу вверху | каталоги |
| `-Mode Auto\|Full\|AddMultimedia\|PyQtOnly` | `Auto` | режим сборки |
| `-QtVersion 6.8.3` | — | нужен только если исходников ещё нет |
| `-UseFFmpeg` | выкл. | собрать FFmpeg-бэкенд Multimedia |
| `-FFmpegUrl <url>` | авто | своя ссылка на zip с shared-сборкой FFmpeg |
| `-Jobs N` | авто | число параллельных задач |
| `-Clean` | выкл. | удалить каталоги сборки перед конфигурацией |
| `-CheckOnly` | выкл. | только проверки, без сборки |
| `-SkipPrereqInstall` | выкл. | ничего не устанавливать, только проверять |
| `-Python <путь>` | `python` из PATH | интерпретатор (64-bit), для которого собираются биндинги; можно указать `python.exe` из venv |
| `-SkipPyQt` | выкл. | не собирать PyQt |
| `-PyQtVersion 6.8.1` | авто | конкретная версия PyQt6 |
| `-PyQtWebEngineVersion 6.8.0` | авто | конкретная версия PyQt6-WebEngine |
| `-AddQtToPath` | выкл. | добавить `C:\qt6install\bin` в PATH пользователя |

Логи каждого запуска сохраняются в `C:\dev\logs\build-qt-<дата>.log`.

---

## 4. Какой бэкенд Multimedia выбрать

- **Windows Media Foundation** (по умолчанию). Ничего дополнительно ставить не нужно. Проигрывает `.mp4` (H.264/AAC) системными кодеками Windows.
- **FFmpeg** (`-UseFFmpeg`). Поддерживает больше форматов и одинаково ведёт себя на разных платформах; в Qt 6.5+ это рекомендуемый бэкенд. DLL FFmpeg копируются в `C:\qt6install\bin`, и их нужно поставлять вместе с приложением. Сборка LGPL: при распространении соблюдайте условия LGPL.

---

## 5. Использование в проекте

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

Деплой:
```
C:\qt6install\bin\windeployqt.exe --release path\to\app.exe
```

### Python (PyQt6)

PyQt6, собранный из исходников, **не содержит Qt DLL внутри**. При импорте он ищет `Qt6Core.dll` в каталогах из `PATH`, поэтому `C:\qt6install\bin` должен быть в `PATH`. Это делает ключ `-AddQtToPath`; изменение действует в новых окнах терминала и IDE. Есть и другой вариант — добавить каталог в самом коде до импорта PyQt6:

```python
import os
os.add_dll_directory(r"C:\qt6install\bin")
os.environ["PATH"] = r"C:\qt6install\bin;" + os.environ["PATH"]  # для QtWebEngineProcess

from PyQt6.QtWidgets import QApplication
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtMultimedia import QMediaPlayer
```

Поставить те же колёса в другое окружение (venv) можно так. Python должен быть той же версии, что и при сборке:
```powershell
pip uninstall -y PyQt6 PyQt6-Qt6 PyQt6-WebEngine PyQt6-WebEngine-Qt6
pip install PyQt6-sip
pip install --no-deps C:\dev\wheels\PyQt6-*.whl C:\dev\wheels\PyQt6_WebEngine-*.whl
```
Если версия Python другая, пересоберите колёса: `-Mode PyQtOnly -Python <путь к python.exe>`.

Следите, чтобы `requirements.txt` или `pip install -r ...` не притянули снова `PyQt6-Qt6` с PyPI: тогда PyQt6 начнёт грузить чужой Qt без кодеков.

Проверка .mp4 в WebEngine: откройте в своём приложении `https://html5test.co/` или любой сайт с H.264-видео.

---

## 6. Частые проблемы

| Симптом | Что делать |
|---|---|
| `Proprietary codecs не включились` | Поддержка кодеков в WebEngine не включилась. Смотрите `C:\qt6build\config.summary` и лог configure. |
| Ошибки `path too long` / `filename longer than 260` | Включите длинные пути (п. 1.2) и перезагрузитесь. |
| `fatal error C1060: out of heap space`, зависание при линковке | Уменьшите параллельность, например `-Jobs 4`. |
| Не скачивается FFmpeg (404) | BtbN периодически убирает старые ветки. Возьмите актуальную ссылку `...-win64-lgpl-shared-...zip` на https://github.com/BtbN/FFmpeg-Builds/releases и передайте её через `-FFmpegUrl`. Другой вариант — распаковать архив вручную в `C:\dev\ffmpeg` (внутри должны быть `include`, `lib`, `bin`). |
| Не скачивается gperf (SourceForge) | Скачайте `gperf-3.0.1-bin.zip` с https://gnuwin32.sourceforge.net/packages/gperf.htm вручную и распакуйте в `C:\dev\tools\gperf` (должен получиться `C:\dev\tools\gperf\bin\gperf.exe`). |
| `python` открывает Microsoft Store | См. п. 1.3. |
| После установки инструментов «команда не найдена» | Закройте PowerShell, откройте новый и запустите скрипт ещё раз. Уже сделанные шаги он пропустит. |
| Нужно начать заново | Запустите с ключом `-Clean`. |
| `QtGui/QtGuimod.sip could not be found` при сборке PyQt6-WebEngine, или в PyQt6 нет QtGui/QtWidgets | В `qt_lib_entrypoint_private.pri` остался `DEFINES = QT_NEEDS_QMAIN` от MinGW. С ним `main` переименовывается в `qMain`, и линковка GUI-тестов падает с `LNK2019: unresolved external symbol main`. Скрипт убирает этот макрос и проверяет, что в колесе есть все нужные модули. |
| `sip-wheel: There are no bindings that can be built` | В `C:\qt6install\mkspecs\modules\*.pri` попал `-lmingw32`, потому что во время прошлой сборки в PATH был MinGW. qmake добавляет `mingw32.lib`, и MSVC-линковка падает. Скрипт сам убирает этот флаг (оставляет копию `.bak`). |
| В логе `cmake` из `C:\Strawberry\c\bin` или пути `C:\msys64\...` | Это MinGW-инструменты, они мешают MSVC-сборке. На время работы скрипт убирает их из PATH и запрещает CMake искать там библиотеки (`CMAKE_IGNORE_PREFIX_PATH`). Если что-то собираете вручную, делайте так же. |
| Режим `Full` выбран, хотя WebEngine уже есть | Если `config.summary` нет, скрипт проверяет кодеки по `Qt6WebEngineCore.dll`. Режим можно задать и явно: `-Mode AddMultimedia`. |
| `В C:\qt6install нет Qt Multimedia` | Сначала соберите Multimedia (`-Mode AddMultimedia`), потом PyQt. |
| `Could not find the Qt platform plugin "windows"` | Осталась папка `site-packages\PyQt6\Qt6` от `PyQt6-Qt6` с PyPI. Пока она есть, PyQt6 считает её корнем Qt и ищет плагины там. Удалите её; скрипт делает это сам. Проверить можно так: `python -c "from PyQt6.QtCore import QLibraryInfo as L; print(L.path(L.LibraryPath.PrefixPath))"`, должно вывести `C:/qt6install`. |
| `ImportError: DLL load failed` при `from PyQt6 import ...` | `C:\qt6install\bin` не в `PATH` (см. раздел «Python (PyQt6)»). Ещё одна возможная причина — остался `PyQt6-Qt6` с PyPI: проверьте `pip list`. |
| `Нужен 64-битный Python` | Поставьте 64-битный CPython и передайте путь через `-Python`. |
| `PyQt6 для Qt X.Y не найден` | Qt новее последнего PyQt6 на PyPI. Скрипт возьмёт ближайшую более старую версию; часть самых новых API Qt в Python будет недоступна. |
| Ошибка компиляции в sip-wheel | Версии PyQt6 и Qt сильно расходятся. Задайте их явно: `-PyQtVersion` / `-PyQtWebEngineVersion`. |
| `.mp4` в PyQt6 WebEngine всё равно не играет | Проверьте, какой Qt реально загружен: `python -c "from PyQt6 import QtCore; print(QtCore.QLibraryInfo.path(QtCore.QLibraryInfo.LibraryPath.PrefixPath))"`. Должно вывести `C:/qt6install`. |

Скрипт можно запускать повторно: уже установленные инструменты, скачанные архивы и исходники он пропускает.
