#!/usr/bin/env bash
# Build a self-updating nimshell AppImage.
#
#   packaging/build-appimage.sh [version]
#
# Produces dist/nimshell-<arch>.AppImage and its .zsync. The update info
# embedded in the image points at this repo's GitHub releases, so
# AppImageUpdate / appimageupdatetool can delta-update it; nimshell itself
# updates via `self-update` (see src/nimshell/update.nim).
#
# Needs: nim, patchelf, and appimagetool (downloaded if not on PATH).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(sed -n 's/^version *= *"\(.*\)"/\1/p' nimshell.nimble)}"
VERSION="${VERSION#v}"
REPO="${NIMSHELL_REPO:-codegod100/nimshell}"
ARCH="$(uname -m)"
APPDIR="build/AppDir"
LIBDIR="/usr/lib/${ARCH}-linux-gnu"

rm -rf "$APPDIR" dist
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" dist

echo ">> building nimshell $VERSION ($ARCH)"
nim c -d:release --hints:off \
  -d:NimshellVersion="$VERSION" -d:UpdateRepo="$REPO" \
  -o:"$APPDIR/usr/bin/nimshell" src/nimshell.nim

# nimshell dlopen()s PCRE (find --regex) and OpenSSL (http, self-update).
# Bundle them and point the binary's RUNPATH at them. No LD_LIBRARY_PATH,
# so external commands started from the shell see the host's libraries.
for lib in libpcre.so.3 libssl.so.3 libcrypto.so.3; do
  cp -L "$LIBDIR/$lib" "$APPDIR/usr/lib/"
done
patchelf --set-rpath '$ORIGIN/../lib' "$APPDIR/usr/bin/nimshell"

ln -s usr/bin/nimshell "$APPDIR/AppRun"
cp packaging/nimshell.desktop "$APPDIR/"
cp packaging/nimshell.svg "$APPDIR/nimshell.svg"

TOOL="$(command -v appimagetool || true)"
if [ -z "$TOOL" ]; then
  TOOL="build/appimagetool"
  if [ ! -x "$TOOL" ]; then
    curl -fsSL -o "$TOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
    chmod +x "$TOOL"
  fi
fi

OUT="dist/nimshell-${ARCH}.AppImage"
# Runs without FUSE (CI containers): extract-and-run the tool itself.
( cd dist && ARCH="$ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "../$TOOL" --no-appstream \
    -u "gh-releases-zsync|${REPO%%/*}|${REPO##*/}|latest|nimshell-${ARCH}.AppImage.zsync" \
    "../$APPDIR" "$(basename "$OUT")" )

echo ">> smoke test"
APPIMAGE_EXTRACT_AND_RUN=1 "$OUT" --version
APPIMAGE_EXTRACT_AND_RUN=1 "$OUT" -c 'range 3 | to json --raw'
ls -l dist/
