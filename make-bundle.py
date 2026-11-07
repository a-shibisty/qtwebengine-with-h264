"""
Builds C:\\dev\\pyqt-bundle - everything needed to install PyQt6 + PyQt6-WebEngine
(with H.264/AAC) on another PC without building Qt:

  pyqt6-*.whl, pyqt6_webengine-*.whl   - bindings (copied from C:\\dev\\wheels)
  pyqt6_qt6_local-*.whl                - Qt runtime from C:\\qt6install, installs into PyQt6\\Qt6
  PyQt6_sip-*.whl                      - sip runtime for Python 3.10-3.13 (for offline install)
  install.ps1, install.cmd, check.py, README.md

Run:  python make-bundle.py [--qt DIR] [--wheels DIR] [--out DIR] [--files DIR]  (build-qt.ps1 calls it)
"""
import argparse, base64, glob, hashlib, io, os, re, shutil, subprocess, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
_ap = argparse.ArgumentParser(description="Build the PyQt6 + Qt runtime bundle")
_ap.add_argument("--qt", default=r"C:\qt6install", help="Qt install prefix")
_ap.add_argument("--wheels", default=r"C:\dev\wheels", help="folder with pyqt6-*.whl and pyqt6_webengine-*.whl")
_ap.add_argument("--out", default=r"C:\dev\pyqt-bundle", help="output bundle folder")
_ap.add_argument("--files", default=os.path.join(HERE, "bundle-files"), help="folder with install.ps1, install.cmd, check.py, README.md")
_ap.add_argument("--python-installer", default="3.12.10", help="python.org installer version to put into the bundle ('' = none)")
_ap.add_argument("--scripts-only", action="store_true", help="only refresh install.ps1/install.cmd/check.py/README.md")
ARGS = _ap.parse_args()
QT, WHEELS, OUT, FILES, PY_INSTALLER = ARGS.qt, ARGS.wheels, ARGS.out, ARGS.files, ARGS.python_installer
SCRIPT_FILES = ("install.ps1", "install.cmd", "check.py", "README.md")

def qt_version():
    txt = open(os.path.join(QT, "mkspecs", "qconfig.pri"), encoding="utf-8").read()
    return re.search(r"QT_VERSION\s*=\s*([\d.]+)", txt).group(1)

def vc_runtime_dlls():
    pats = [r"C:\Program Files\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT\*.dll",
            r"C:\Program Files (x86)\Microsoft Visual Studio\2022\*\VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT\*.dll"]
    files = []
    for p in pats:
        files += glob.glob(p)
    # take the newest redist version only
    files.sort()
    by_name = {}
    for f in files:
        by_name[os.path.basename(f).lower()] = f
    return list(by_name.values())

def collect():
    """(source path, path inside PyQt6/Qt6) pairs"""
    items = []
    b = os.path.join(QT, "bin")
    for n in sorted(os.listdir(b)):
        low = n.lower()
        if low.endswith(".dll") or low == "qtwebengineprocess.exe":
            items.append((os.path.join(b, n), "bin/" + n))
    vc = vc_runtime_dlls()
    if not vc:
        sys.exit("MSVC runtime DLLs not found (VC\\Redist\\MSVC\\...\\Microsoft.VC14*.CRT) - install VS 2022 C++ tools")
    for f in vc:
        items.append((f, "bin/" + os.path.basename(f)))
    for sub in ("plugins", "resources", "translations", "qml"):
        root = os.path.join(QT, sub)
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            for n in fn:
                if n.lower().endswith((".pdb", ".lib", ".prl", ".cmake")):
                    continue
                src = os.path.join(dp, n)
                items.append((src, sub + "/" + os.path.relpath(src, root).replace("\\", "/")))
    return items

def b64hash(data_iter):
    h = hashlib.sha256(); size = 0
    for chunk in data_iter:
        h.update(chunk); size += len(chunk)
    return "sha256=" + base64.urlsafe_b64encode(h.digest()).rstrip(b"=").decode(), size

def file_chunks(path):
    with open(path, "rb") as f:
        while True:
            c = f.read(1 << 20)
            if not c:
                return
            yield c

def build_runtime_wheel(ver):
    name, dist = "PyQt6-Qt6-Local", "pyqt6_qt6_local"
    whl = os.path.join(OUT, f"{dist}-{ver}-py3-none-win_amd64.whl")
    info = f"{dist}-{ver}.dist-info"
    items = collect()
    print(f"Qt runtime: {len(items)} files")
    record = []
    with zipfile.ZipFile(whl, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for src, rel in items:
            arc = "PyQt6/Qt6/" + rel
            z.write(src, arc)
            h, s = b64hash(file_chunks(src))
            record.append(f"{arc},{h},{s}")
        meta = {
            f"{info}/METADATA": (f"Metadata-Version: 2.1\nName: {name}\nVersion: {ver}\n"
                                 f"Summary: Qt {ver} runtime (WebEngine with proprietary codecs, Multimedia) for PyQt6, built locally\n"
                                 "Requires-Python: >=3.10\n"),
            f"{info}/WHEEL": "Wheel-Version: 1.0\nGenerator: make-bundle\nRoot-Is-Purelib: false\nTag: py3-none-win_amd64\n",
        }
        for arc, text in meta.items():
            data = text.encode()
            z.writestr(arc, data)
            h, s = b64hash([data])
            record.append(f"{arc},{h},{s}")
        record.append(f"{info}/RECORD,,")
        z.writestr(f"{info}/RECORD", "\n".join(record) + "\n")
    print(f"Built {whl} ({os.path.getsize(whl) // (1 << 20)} MB)")

def main():
    ver = qt_version()
    if ARGS.scripts_only:
        os.makedirs(OUT, exist_ok=True)
        for f in SCRIPT_FILES:
            shutil.copy2(os.path.join(FILES, f), OUT)
        print("Scripts updated in", OUT)
        return
    os.makedirs(OUT, exist_ok=True)
    for f in glob.glob(os.path.join(OUT, "pyqt6*.whl")):   # only our own wheels
        os.remove(f)
    for pat in ("pyqt6-*.whl", "pyqt6_webengine-*.whl"):
        found = sorted(glob.glob(os.path.join(WHEELS, pat)), key=os.path.getmtime)
        if not found:
            sys.exit(f"No {pat} in {WHEELS}")
        shutil.copy2(found[-1], OUT)
        print("Copied", os.path.basename(found[-1]))
    build_runtime_wheel(ver)
    for pyver in ("3.10", "3.11", "3.12", "3.13", "3.14"):
        r = subprocess.run([sys.executable, "-m", "pip", "download", "--quiet", "--disable-pip-version-check",
                            "PyQt6-sip>=13.13,<14", "--only-binary=:all:", "--no-deps",
                            "--platform", "win_amd64", "--python-version", pyver, "-d", OUT])
        if r.returncode != 0:
            print(f"  (PyQt6-sip for Python {pyver} not downloaded - it will be installed from PyPI)")
    # Python installer for a clean PC (installed per-user by install.ps1 if no Python 3.10+ is found)
    pyinst = os.path.join(OUT, f"python-{PY_INSTALLER}-amd64.exe")
    if PY_INSTALLER and not os.path.exists(pyinst):
        url = f"https://www.python.org/ftp/python/{PY_INSTALLER}/python-{PY_INSTALLER}-amd64.exe"
        print("Downloading", url)
        try:
            import urllib.request
            urllib.request.urlretrieve(url, pyinst + ".part")
            os.replace(pyinst + ".part", pyinst)
        except Exception as e:
            print(f"  (not downloaded: {e}) - install.ps1 will download it on the target PC if it has internet")
    for f in SCRIPT_FILES:
        src = os.path.join(FILES, f)
        if not os.path.exists(src):
            sys.exit(f"Missing {src}")
        shutil.copy2(src, OUT)
    print("\nDone:", OUT)
    for f in sorted(os.listdir(OUT)):
        print(f"  {os.path.getsize(os.path.join(OUT, f)) // 1024:>8} KB  {f}")

if __name__ == "__main__":
    main()
