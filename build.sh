#!/bin/zsh
# Usage: ./build.sh            -> build/DisplayDial.app
#        ./build.sh install    -> also copies it to /Applications and launches it
#        ./build.sh check      -> hardware self-check (DDC write round-trip)
#        ./build.sh screenshots -> renders docs/panel-{light,dark}.png from the live monitor
#        ./build.sh dmg        -> also packages build/DisplayDial.dmg and .zip for sharing
set -e
cd "${0:a:h}"
if [[ $1 == check ]]; then
  mkdir -p build
  swiftc Sources/DDC.swift Tests/main.swift -o build/check
  exec build/check
fi
# Version comes from the latest vX.Y.Z git tag; the build number is the commit count.
VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')
VERSION=${VERSION:-0.0.0}
if [[ $1 == screenshots ]]; then
  mkdir -p build
  # A bare executable has no bundle, so embed an Info.plist for the panel's version label.
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>' $VERSION > build/screenshots-Info.plist
  swiftc -O -D SCREENSHOTS -target arm64-apple-macos14.0 Sources/*.swift -o build/screenshots \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker build/screenshots-Info.plist
  exec build/screenshots
fi
APP=build/DisplayDial.app
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
rm -rf $APP && mkdir -p $APP/Contents/{MacOS,Resources}
cp Resources/AppIcon.icns Resources/MenuBarIconTemplate.pdf $APP/Contents/Resources/
swiftc -O -target arm64-apple-macos14.0 Sources/*.swift -o $APP/Contents/MacOS/DisplayDial
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DisplayDial</string>
  <key>CFBundleIdentifier</key><string>local.displaydial</string>
  <key>CFBundleExecutable</key><string>DisplayDial</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Grab Connected Tech LLC. grabians.com</string>
</dict></plist>
PLIST
codesign --force -s - $APP
echo "Built $APP $VERSION ($BUILD)"
if [[ $1 == install ]]; then
  pkill -x DisplayDial || true
  rm -rf /Applications/DisplayDial.app && cp -R $APP /Applications/
  open /Applications/DisplayDial.app
  echo "Installed to /Applications"
fi
if [[ $1 == dmg ]]; then
  STAGE=build/dmg && rm -rf $STAGE build/DisplayDial.dmg build/DisplayDial.zip && mkdir -p $STAGE
  cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
  hdiutil create -volname DisplayDial -srcfolder $STAGE -format UDZO -quiet build/DisplayDial.dmg
  rm -rf $STAGE
  ditto -c -k --keepParent $APP build/DisplayDial.zip
  echo "Created build/DisplayDial.dmg and build/DisplayDial.zip"
fi
