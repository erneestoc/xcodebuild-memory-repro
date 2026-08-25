#!/bin/bash
# Builds the app + hosted test bundle + .xctestrun with plain `swiftc`
# (no Xcode project needed). PAD_MB=<n> embeds n MB of __TEXT padding in the
# host app binary to model a production-sized app.
source "$(dirname "$0")/common.sh"

PAD_MB="${PAD_MB:-0}"
TEST_PAD_MB="${TEST_PAD_MB:-0}"
DYLIB_PAD_MB="${DYLIB_PAD_MB:-0}"
FIXTURE="$(fixture_path "$PAD_MB" "$TEST_PAD_MB" "$DYLIB_PAD_MB")"
APP="$FIXTURE/App.app"
rm -rf "$FIXTURE"
mkdir -p "$APP/PlugIns/MemTests.xctest"

make_pad() { # <size_mb> <path>
  mkfile -n "${1}m" "$2" 2>/dev/null \
    || dd if=/dev/zero of="$2" bs=1048576 count="$1" status=none
}

pad_args=()
if [[ "$PAD_MB" -gt 0 ]]; then
  make_pad "$PAD_MB" "$FIXTURE/pad.bin"
  pad_args=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __pad -Xlinker "$FIXTURE/pad.bin")
fi

# Same inert padding, applied to the test bundle binary instead of the host
# app, to separate "cost of the app under test" from "cost of the test code".
test_pad_args=()
if [[ "$TEST_PAD_MB" -gt 0 ]]; then
  make_pad "$TEST_PAD_MB" "$FIXTURE/testpad.bin"
  test_pad_args=(-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __pad -Xlinker "$FIXTURE/testpad.bin")
fi

# An embedded dynamic library carrying the padding, standing in for a project
# that moves its code into dynamic frameworks rather than linking it statically
# into the app or test binary.
dylib_link_args=()
if [[ "$DYLIB_PAD_MB" -gt 0 ]]; then
  echo "building embedded dylib (pad: ${DYLIB_PAD_MB} MB)..."
  mkdir -p "$APP/Frameworks"
  make_pad "$DYLIB_PAD_MB" "$FIXTURE/dylibpad.bin"
  xcrun swiftc "$ROOT/Sources/PadLib.swift" \
    -emit-library -module-name PadLib \
    -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __pad -Xlinker "$FIXTURE/dylibpad.bin" \
    -Xlinker -install_name -Xlinker "@rpath/libPadLib.dylib" \
    -o "$APP/Frameworks/libPadLib.dylib"
  # -needed-l keeps the load command even though the app calls nothing in it.
  dylib_link_args=(-L"$APP/Frameworks" -Xlinker -needed-lPadLib
                   -Xlinker -rpath -Xlinker "@executable_path/Frameworks")
fi

echo "building host app (app pad: ${PAD_MB} MB, test pad: ${TEST_PAD_MB} MB, dylib pad: ${DYLIB_PAD_MB} MB)..."
xcrun swiftc "$ROOT/Sources/AppMain.swift" \
  -parse-as-library \
  -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
  ${pad_args[@]+"${pad_args[@]}"} \
  ${dylib_link_args[@]+"${dylib_link_args[@]}"} \
  -o "$APP/App"

if [[ "$DYLIB_PAD_MB" -gt 0 ]]; then
  otool -L "$APP/App" | grep -q 'libPadLib.dylib' \
    || { echo "error: app does not link libPadLib.dylib; the test would be meaningless" >&2; exit 1; }
  codesign --force --sign - "$APP/Frameworks/libPadLib.dylib" >/dev/null 2>&1
fi

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
  ${test_pad_args[@]+"${test_pad_args[@]}"} \
  -o "$APP/PlugIns/MemTests.xctest/MemTests"

if [[ -n "${TESTCASE_DYLIB:-}" ]]; then
  echo "building XCTestCase subclass into an embedded dylib..."
  mkdir -p "$APP/Frameworks"
  xcrun swiftc "$ROOT/Sources/DylibTests.swift" \
    -emit-library -module-name DylibTests \
    -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
    -F "$PLATFORM_DIR/Developer/Library/Frameworks" \
    -I "$PLATFORM_DIR/Developer/usr/lib" \
    -L "$PLATFORM_DIR/Developer/usr/lib" -lXCTestSwiftSupport \
    -Xlinker -install_name -Xlinker "@rpath/libDylibTests.dylib" \
    -o "$APP/Frameworks/libDylibTests.dylib"
  # Relink the test bundle against it so dyld loads the dylib with the bundle.
  xcrun swiftc "$ROOT/Sources/Tests.swift" \
    -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
    -emit-library -module-name MemTests \
    -F "$PLATFORM_DIR/Developer/Library/Frameworks" \
    -I "$PLATFORM_DIR/Developer/usr/lib" \
    -L "$PLATFORM_DIR/Developer/usr/lib" -lXCTestSwiftSupport \
    -L "$APP/Frameworks" -Xlinker -needed-lDylibTests \
    -Xlinker -rpath -Xlinker "@loader_path/../../Frameworks" \
    ${test_pad_args[@]+"${test_pad_args[@]}"} \
    -o "$APP/PlugIns/MemTests.xctest/MemTests"
  otool -L "$APP/PlugIns/MemTests.xctest/MemTests" | grep -q libDylibTests \
    || { echo "error: test bundle does not link libDylibTests" >&2; exit 1; }
  codesign --force --sign - "$APP/Frameworks/libDylibTests.dylib" >/dev/null 2>&1
fi

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

echo "fixture ready: $FIXTURE (App binary: $(du -h "$APP/App" | cut -f1), \
test binary: $(du -h "$APP/PlugIns/MemTests.xctest/MemTests" | cut -f1))"
