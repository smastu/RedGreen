#!/bin/zsh
# RedGreen.app を ~/Applications に作る（Xcode 不要）
set -e
cd "${0:a:h}"
APP="$HOME/Applications/RedGreen.app"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 main.swift -o build/RedGreen
cp build/RedGreen "$APP/Contents/MacOS/.RedGreen.new"
mv -f "$APP/Contents/MacOS/.RedGreen.new" "$APP/Contents/MacOS/RedGreen"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.matsumoto.RedGreen</string>
<key>CFBundleName</key><string>RedGreen</string>
<key>CFBundleExecutable</key><string>RedGreen</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PL
# 自己署名の証明書で署名する（毎回同じ署名になり、アクセシビリティの許可が消えない）。無ければ ad-hoc
if security find-identity 2>/dev/null | grep -q "Shimpei Local Code Signing"; then
  codesign --force --sign "Shimpei Local Code Signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo built "$APP"
