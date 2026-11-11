#!/bin/sh
# Builds the two herdr-preview helper apps into a folder (default ~/Applications):
#   Herdr Preview Web.app    the WebKit view over the Preview panel
#   Herdr Preview Links.app  routes Cmd-clicked .md links into the Preview panel
# Usage: native/build.sh [apps-dir]
# Needs swiftc (Xcode Command Line Tools). The apps are signed ad hoc on this Mac; nothing is
# downloaded, and the apps never leave it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
apps_dir=${1:-$HOME/Applications}
mkdir -p "$apps_dir"

# build <name> <executable> <bundle-id> <source-dir> <extra-plist-keys>
build() {
  app="$apps_dir/$1.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- No Dock icon or menu bar, and never activated: the Herdr app stays frontmost. -->
  <key>LSUIElement</key><true/>
$5
</dict>
</plist>
PLIST
  swiftc -O "$here/$4/main.swift" -o "$app/Contents/MacOS/$2"
  codesign --force --sign - "$app" >/dev/null 2>&1
  echo "built: $app"
}

build "Herdr Preview Web" HerdrPreviewWeb io.github.tanviirdev.herdr-preview.web web \
'  <!-- Local dev servers and review tools are often plain http on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>'

build "Herdr Preview Links" HerdrPreviewLinks io.github.tanviirdev.herdr-preview.links links \
'  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
    </dict>
  </array>'
