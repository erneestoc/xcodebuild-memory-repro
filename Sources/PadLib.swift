// Stands in for a dynamic framework carrying the bulk of a project's code.
// The padding is linked into this dylib instead of the app or test binary,
// to test whether xcodebuild charges embedded dylibs the same multiplier.
@_cdecl("padLibVersion")
public func padLibVersion() -> Int32 { 1 }
