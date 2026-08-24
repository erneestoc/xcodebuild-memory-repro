#!/bin/bash
# Builds the app + hosted test bundle + .xctestrun with plain `swiftc`
# (no Xcode project needed). PAD_MB=<n> embeds n MB of __TEXT padding in the
# host app binary to model a production-sized app.
source "$(dirname "$0")/common.sh"

PAD_MB="${PAD_MB:-0}"
FIXTURE="$WORK/fixture-pad${PAD_MB}"
APP="$FIXTURE/App.app"
rm -rf "$FIXTURE"
mkdir -p "$APP/PlugIns/MemTests.xctest"

pad_args=()
if [[ "$PAD_MB" -gt 0 ]]; then
  mkfile -n "${PAD_MB}m" "$FIXTURE/pad.bin" 2>/dev/null \
    || dd if=/dev/zero of="$FIXTURE/pad.bin" bs=1048576 count="$PAD_MB" status=none
  pad_args=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __pad -Xlinker "$FIXTURE/pad.bin")
fi

echo "building host app (pad: ${PAD_MB} MB)..."
xcrun swiftc "$ROOT/Sources/AppMain.swift" \
  -parse-as-library \
  -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
  ${pad_args[@]+"${pad_args[@]}"} \
  -o "$APP/App"

/usr/libexec/PlistBuddy -c 'Clear dict' "$APP/Info.plist" 2>/dev/null || true
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>App</string>
  <key>CFBundleIdentifier</key><string>com.example.memrepro.App</string>
  <key>CFBundleName</key><string>App</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchScreen</key><dict/>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PLIST

echo "building test bundle..."
xcrun swiftc "$ROOT/Sources/Tests.swift" \
  -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
  -emit-library -module-name MemTests \
  -F "$PLATFORM_DIR/Developer/Library/Frameworks" \
  -I "$PLATFORM_DIR/Developer/usr/lib" \
  -L "$PLATFORM_DIR/Developer/usr/lib" -lXCTestSwiftSupport \
  -o "$APP/PlugIns/MemTests.xctest/MemTests"

cat > "$APP/PlugIns/MemTests.xctest/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MemTests</string>
  <key>CFBundleIdentifier</key><string>com.example.memrepro.MemTests</string>
  <key>CFBundleName</key><string>MemTests</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP/PlugIns/MemTests.xctest" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1

cat > "$FIXTURE/tests.xctestrun" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>MemTests</key>
  <dict>
    <key>ProductModuleName</key><string>MemTests</string>
    <key>IsAppHostedTestBundle</key><true/>
    <key>TestHostPath</key><string>__TESTROOT__/App.app</string>
    <key>TestHostBundleIdentifier</key><string>com.example.memrepro.App</string>
    <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/MemTests.xctest</string>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>DYLD_INSERT_LIBRARIES</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib/libXCTestBundleInject.dylib</string>
      <key>DYLD_LIBRARY_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
      <key>DYLD_FRAMEWORK_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks</string>
    </dict>
  </dict>
  <key>__xctestrun_metadata__</key>
  <dict><key>FormatVersion</key><integer>1</integer></dict>
</dict></plist>
PLIST

echo "fixture ready: $FIXTURE (App binary: $(du -h "$APP/App" | cut -f1))"
