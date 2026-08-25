import XCTest

// Each experiment drives exactly one of these tests via -only-testing and
// sizes it through REPRO_* environment variables injected into the
// xctestrun's TestingEnvironmentVariables.
class MemTests: XCTestCase {

    private func envMB(_ key: String) -> Int {
        Int(ProcessInfo.processInfo.environment[key] ?? "0") ?? 0
    }

    // Baseline: does nothing. Measures the fixed cost of one
    // `xcodebuild test-without-building` session.
    func testTrivial() {
        XCTAssertTrue(true)
    }

    // Writes REPRO_CONSOLE_MB megabytes to stdout, 1 KiB per line.
    // Host-side memory grows ~26x the bytes written.
    func testEmitConsoleOutput() {
        let mb = envMB("REPRO_CONSOLE_MB")
        guard mb > 0 else { return }
        let line = String(repeating: "x", count: 1023) + "\n"
        let data = line.data(using: .utf8)!
        for _ in 0..<(mb * 1024) {
            FileHandle.standardOutput.write(data)
        }
    }

    // Keeps the test session alive for REPRO_SLEEP_S seconds. Peak host-side
    // memory is reached before the test body runs, so sleeping here holds the
    // xcodebuild process at its peak long enough to inspect it
    // (vmmap / heap / vm_stat) instead of having to catch a ~1 second window.
    func testHoldOpen() {
        let seconds = Int(ProcessInfo.processInfo.environment["REPRO_SLEEP_S"] ?? "0") ?? 0
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
    }

    // Adds one REPRO_ATTACH_MB-megabyte attachment with
    // lifetime = .deleteOnSuccess on a passing test: the payload can never
    // be needed, yet host-side memory still grows ~1.4x its size.
    func testAddAttachment() {
        let mb = envMB("REPRO_ATTACH_MB")
        guard mb > 0 else { return }
        let attachment = XCTAttachment(data: Data(count: mb * 1024 * 1024))
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
