"""Checks that PyQt6 uses the bundled Qt (PyQt6-Qt6-Local) and that .mp4 (H.264/AAC) is supported."""
import sys
from PyQt6.QtCore import QLibraryInfo, QTimer, qVersion, PYQT_VERSION_STR
from PyQt6.QtWidgets import QApplication
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtMultimedia import QMediaFormat

print("PyQt", PYQT_VERSION_STR, "/ Qt", qVersion())
print("Qt prefix:", QLibraryInfo.path(QLibraryInfo.LibraryPath.PrefixPath))
app = QApplication(sys.argv)
dec = QMediaFormat(QMediaFormat.FileFormat.MPEG4).supportedVideoCodecs(QMediaFormat.ConversionMode.Decode)
print("QtMultimedia MP4 + H.264:", QMediaFormat.VideoCodec.H264 in dec)
view = QWebEngineView()
view.setHtml("<video id=v></video>")
result = {"ok": False}
def check(_):
    js = """document.getElementById('v').canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"')"""
    def done(r):
        print("WebEngine canPlayType mp4:", repr(r), "(expected 'probably')")
        result["ok"] = (r == "probably")
        app.quit()
    view.page().runJavaScript(js, done)
view.loadFinished.connect(check)
QTimer.singleShot(20000, app.quit)
app.exec()
sys.exit(0 if result["ok"] else 1)
