# Tools inside the app, pinned by version and SHA-256 (app/fetch-tools.sh checks every file before use). Sourced by bash.
# The shims are pinned in scripts/lib/shims.sh; the app's name and minimum macOS in app/app.conf.
SEVENZIP_VERSION=26.04
SEVENZIP_URL=https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz
SEVENZIP_SHA256=bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578
SEVENZIP_SRC_URL=https://github.com/ip7z/7zip/releases/download/26.04/7z2604-src.tar.xz
SEVENZIP_SRC_SHA256=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6
CABEXTRACT_VERSION=1.11
CABEXTRACT_URL=https://www.cabextract.org.uk/cabextract-1.11.tar.gz
CABEXTRACT_SHA256=b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6
WINETRICKS_VERSION=20260125   # tag 20260125 = commit b76e1ee
WINETRICKS_URL=https://raw.githubusercontent.com/Winetricks/winetricks/b76e1ee79ac57d7aceb384f74518fc423265810c/src/winetricks
WINETRICKS_SHA256=431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b
WINETRICKS_COPYING_URL=https://raw.githubusercontent.com/Winetricks/winetricks/b76e1ee79ac57d7aceb384f74518fc423265810c/COPYING
WINETRICKS_COPYING_SHA256=dc626520dcd53a22f727af3ee42c770e56c97a64fe3adb063799d8ab032fe551
PYTHON_VERSION=3.14.8         # python-build-standalone 20261013, aarch64
PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.14.8%2B20261013-aarch64-apple-darwin-install_only.tar.gz
PYTHON_SHA256=709f419d175eb015f810b68aa54bdae1d776c9824cb362aa701c93b0a9f2a9e7
# the same build's full archive, only for python/licenses/ and PYTHON.json (install_only has no dependency licenses)
PYTHON_FULL_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261013/cpython-3.14.8%2B20261013-aarch64-apple-darwin-pgo%2Blto-full.tar.zst
PYTHON_FULL_SHA256=5806ddb9d95d73796c87e1aeb45bf7ec984d08ae9eb94f9020436052b32ce498
