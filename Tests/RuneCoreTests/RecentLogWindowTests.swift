import Foundation
import XCTest
@testable import RuneCore

final class RecentLogWindowTests: XCTestCase {
    func testRecentMinutesDefaultPersistAndStayPositive() throws {
        let suite = "RecentLogWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(defaults.runeRecentLogWindowMinutes, 5)
        defaults.runeRecentLogWindowMinutes = 12
        XCTAssertEqual(UserDefaults(suiteName: suite)?.runeRecentLogWindowMinutes, 12)
        defaults.runeRecentLogWindowMinutes = 0
        XCTAssertEqual(defaults.runeRecentLogWindowMinutes, 1)
    }
}
