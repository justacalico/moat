#!/usr/bin/env bash
# Package a built Flutter Linux bundle into tar.gz, zip, .deb, .rpm and
# AppImage. Layout matches between formats: /opt/moat + /usr/bin/moat symlink.
#
# Usage: scripts/package-linux.sh <bundle-dir> <version> <arch> <outdir> [release]
#   arch: x64 or arm64 (the flutter build directory name)
set -euo pipefail

BUNDLE_DIR="${1:?usage: package-linux.sh <bundle-dir> <version> <arch> <outdir> [release]}"
VERSION="${2:?}"
FLUTTER_ARCH="${3:?}"
OUTDIR="${4:?}"
RELEASE="${5:-1}"
ICON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/linux/moat.png"

case "$FLUTTER_ARCH" in
  x64)   OUT_ARCH=x86_64; DEB_ARCH=amd64; RPM_ARCH=x86_64; APPIMAGE_ARCH=x86_64 ;;
  arm64) OUT_ARCH=arm64;  DEB_ARCH=arm64; RPM_ARCH=aarch64; APPIMAGE_ARCH=aarch64 ;;
  *) echo "package-linux: unsupported arch $FLUTTER_ARCH" >&2; exit 1 ;;
esac

[ -d "$BUNDLE_DIR" ] || { echo "missing bundle: $BUNDLE_DIR" >&2; exit 1; }
mkdir -p "$OUTDIR"

# --- tar.gz + zip -------------------------------------------------------
tar -czf "$OUTDIR/moat-linux-$OUT_ARCH.tar.gz" -C "$BUNDLE_DIR" .
(cd "$BUNDLE_DIR" && zip -qr "$OUTDIR/moat-linux-$OUT_ARCH.zip" .)

DESKTOP_FILE='[Desktop Entry]
Type=Application
Name=Moat
Comment=Local-first encrypted notes
Exec=moat
Icon=moat
Categories=Office;Utility;
Terminal=false'

# --- .deb ---------------------------------------------------------------
PKGDIR="$(mktemp -d)"
mkdir -p "$PKGDIR/opt/moat" "$PKGDIR/usr/bin" "$PKGDIR/usr/share/applications" \
  "$PKGDIR/usr/share/icons/hicolor/1024x1024/apps" "$PKGDIR/DEBIAN"
cp -a "$BUNDLE_DIR/." "$PKGDIR/opt/moat/"
ln -sf /opt/moat/moat "$PKGDIR/usr/bin/moat"
printf '%s\n' "$DESKTOP_FILE" > "$PKGDIR/usr/share/applications/moat.desktop"
cp "$ICON" "$PKGDIR/usr/share/icons/hicolor/1024x1024/apps/moat.png"
cat > "$PKGDIR/DEBIAN/control" <<EOD
Package: moat
Version: $VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Moat CI <ci@gitlab.com>
Description: Local-first encrypted notes with serverless LAN sync
EOD
dpkg-deb --build "$PKGDIR" "$OUTDIR/moat-linux-$OUT_ARCH.deb" >/dev/null
rm -rf "$PKGDIR"

# --- .rpm ---------------------------------------------------------------
if command -v rpmbuild >/dev/null 2>&1; then
  RPM_VERSION="$(printf '%s' "$VERSION" | tr '-' '~')"
  TOPDIR="$(mktemp -d)"
  mkdir -p "$TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cat > "$TOPDIR/SPECS/moat.spec" <<EOD
Name: moat
Version: %{pkg_version}
Release: %{pkg_release}%{?dist}
Summary: Local-first encrypted notes
License: AGPL-3.0-only
URL: https://gitlab.com/HttpAnimations/moat
%global debug_package %{nil}
%global __os_install_post %{nil}
%global __provides_exclude_from ^/opt/moat/.*

%description
Local-first encrypted notes with serverless LAN sync.

%install
mkdir -p %{buildroot}/opt/moat %{buildroot}/usr/bin %{buildroot}/usr/share/applications %{buildroot}/usr/share/icons/hicolor/1024x1024/apps
cp -a %{bundle_dir}/. %{buildroot}/opt/moat/
ln -sf /opt/moat/moat %{buildroot}/usr/bin/moat
install -m644 %{desktop_file} %{buildroot}/usr/share/applications/moat.desktop
install -m644 %{icon_file} %{buildroot}/usr/share/icons/hicolor/1024x1024/apps/moat.png

%files
/opt/moat
/usr/bin/moat
/usr/share/applications/moat.desktop
/usr/share/icons/hicolor/1024x1024/apps/moat.png
EOD
  printf '%s\n' "$DESKTOP_FILE" > "$TOPDIR/moat.desktop"
  rpmbuild -bb \
    --target "$RPM_ARCH" \
    --define "_topdir $TOPDIR" \
    --define "pkg_version $RPM_VERSION" \
    --define "pkg_release $RELEASE" \
    --define "bundle_dir $(realpath "$BUNDLE_DIR")" \
    --define "desktop_file $TOPDIR/moat.desktop" \
    --define "icon_file $ICON" \
    "$TOPDIR/SPECS/moat.spec" >/dev/null
  find "$TOPDIR/RPMS" -name '*.rpm' -exec cp {} "$OUTDIR/moat-linux-$OUT_ARCH.rpm" \;
  rm -rf "$TOPDIR"
fi

# --- AppImage -------------------------------------------------------------
APPIMAGETOOL=/tmp/appimagetool
if [ ! -x "$APPIMAGETOOL" ]; then
  curl -fsSL --retry 3 -o "$APPIMAGETOOL" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$APPIMAGE_ARCH.AppImage"
  chmod +x "$APPIMAGETOOL"
fi
APPDIR="$(mktemp -d)/Moat.AppDir"
mkdir -p "$APPDIR/opt/moat"
cp -a "$BUNDLE_DIR/." "$APPDIR/opt/moat/"
printf '%s\n' "$DESKTOP_FILE" | sed 's|Exec=moat|Exec=opt/moat/moat|' > "$APPDIR/moat.desktop"
cp "$ICON" "$APPDIR/moat.png"
cp "$ICON" "$APPDIR/.DirIcon"
cat > "$APPDIR/AppRun" <<'EOD'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/opt/moat/moat" "$@"
EOD
chmod +x "$APPDIR/AppRun"
ARCH="$APPIMAGE_ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTDIR/moat-linux-$OUT_ARCH.AppImage" >/dev/null 2>&1 \
  || { echo "package-linux: appimagetool failed"; }

echo "package-linux: artifacts in $OUTDIR"
ls -la "$OUTDIR"
