import XCTest

// An XCTestCase subclass that lives in an embedded dynamic library rather
// than in the .xctest bundle binary, to check whether XCTest still discovers
// it. If it is discovered, test code itself can be moved out of the bundle;
// if not, only the code the tests depend on can be.
public class DylibHostedTests: XCTestCase {
    public func testFromDylib() {
        XCTAssertTrue(true)
    }
}
