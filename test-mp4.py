"""Check H.264/AAC (.mp4) support in PyQt6 WebEngine and Qt Multimedia.
Run with --debug to print Qt plugin loading details."""
import os, sys
if "--debug" in sys.argv:
    os.environ["QT_DEBUG_PLUGINS"] = "1"

print("python:", sys.executable)
print("Qt6Core.dll in PATH (first one wins in PyQt6):")
for p in os.environ.get("PATH", "").split(";"):
    if p and os.path.isfile(os.path.join(p, "Qt6Core.dll")):
        print("   ", p)
for k in sorted(os.environ):
    if k.upper().startswith(("QT_", "QML")):
        print(f"env {k}={os.environ[k]}")

os.add_dll_directory(r"C:\qt6install\bin")
from PyQt6 import QtCore
from PyQt6.QtCore import QLibraryInfo

import ctypes
from ctypes import wintypes
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.GetModuleHandleW.restype = wintypes.HMODULE
k32.GetModuleFileNameW.argtypes = [wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
buf = ctypes.create_unicode_buffer(1024)
k32.GetModuleFileNameW(k32.GetModuleHandleW("Qt6Core.dll"), buf, 1024)
print("PyQt6.QtCore:", QtCore.__file__)
print("loaded Qt6Core.dll:", buf.value)
print("Qt version:", QtCore.qVersion())
print("Qt prefix:", QLibraryInfo.path(QLibraryInfo.LibraryPath.PrefixPath))
print("Qt plugins:", QLibraryInfo.path(QLibraryInfo.LibraryPath.PluginsPath))
sys.stdout.flush()

from PyQt6.QtCore import QTimer
from PyQt6.QtWidgets import QApplication
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtMultimedia import QMediaFormat

app = QApplication(sys.argv)

fmt = QMediaFormat(QMediaFormat.FileFormat.MPEG4)
dec = fmt.supportedVideoCodecs(QMediaFormat.ConversionMode.Decode)
print("QtMultimedia MP4 + H.264:", QMediaFormat.VideoCodec.H264 in dec)

view = QWebEngineView()
view.setHtml("<video id=v></video>")

def check(ok):
    js = """[document.getElementById('v').canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"'),
             MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E"')]"""
    def done(r):
        print("WebEngine canPlayType mp4:", repr(r[0]), "(expected 'probably')")
        print("WebEngine MSE H.264:", r[1])
        app.quit()
    view.page().runJavaScript(js, done)

view.loadFinished.connect(check)
QTimer.singleShot(15000, app.quit)
app.exec()
