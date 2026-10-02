import XCTest
@testable import LoupecastCore

final class VersionTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(Version.isNewer("v0.3.0", than: "0.2.0"))
        XCTAssertTrue(Version.isNewer("v0.10.0", than: "0.9.1"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "0.99.99"))
        XCTAssertFalse(Version.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(Version.isNewer("v0.1.9", than: "0.2.0"))
    }
}
