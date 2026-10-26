#!/bin/zsh
# Usage: ./build.sh            -> build/DisplayDial.app
#        ./build.sh install    -> also copies it to /Applications and launches it
#        ./build.sh check      -> hardware self-check (DDC write round-trip)
#        ./build.sh dmg        -> also packages build/DisplayDial.dmg for sharing
set -e
cd "${0:a:h}"
if [[ $1 == check ]]; then
  mkdir -p build
  swiftc Sources/DDC.swift Tests/main.swift -o build/check
  exec build/check
fi
APP=build/DisplayDial.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O -target arm64-apple-macos14.0 Sources/*.swift -o $APP/Contents/MacOS/DisplayDial
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DisplayDial</string>
  <key>CFBundleIdentifier</key><string>local.displaydial</string>
  <key>CFBundleExecutable</key><string>DisplayDial</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - $APP
echo "Built $APP"
if [[ $1 == install ]]; then
  pkill -x DisplayDial || true
  rm -rf /Applications/DisplayDial.app && cp -R $APP /Applications/
  open /Applications/DisplayDial.app
  echo "Installed to /Applications"
fi
if [[ $1 == dmg ]]; then
  STAGE=build/dmg && rm -rf $STAGE build/DisplayDial.dmg && mkdir -p $STAGE
  cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
  hdiutil create -volname DisplayDial -srcfolder $STAGE -format UDZO -quiet build/DisplayDial.dmg
  rm -rf $STAGE
  echo "Created build/DisplayDial.dmg"
fi
