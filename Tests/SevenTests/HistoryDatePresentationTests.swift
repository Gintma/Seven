import Foundation
import XCTest
@testable import Seven

final class HistoryDatePresentationTests: XCTestCase {
    func testChineseDatesUseCalendarBoundariesAndDetailsRetainSeconds() throws {
        try L10n.$languageOverride.withValue(.simplifiedChinese) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10, minute: Int = 13) throws -> Date {
                try XCTUnwrap(calendar.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute, second: 7
                )))
            }
            let today = try date(2026, 11, 25)
            let format = HistoryDatePresentation(now: today, calendar: calendar)
            XCTAssertEqual(format.row(today), "今天 10:13")
            XCTAssertEqual(format.row(try date(2026, 11, 24)), "昨天 10:13")
            XCTAssertEqual(format.row(try date(2026, 10, 10)), "10月10日")
            XCTAssertEqual(format.row(try date(2025, 11, 25)), "2025/11/25")
            XCTAssertEqual(format.detail(today), "2026年11月25日 10:13:07")

            let newYear = try date(2027, 1, 1, hour: 0, minute: 1)
            let newYearFormat = HistoryDatePresentation(now: newYear, calendar: calendar)
            XCTAssertEqual(newYearFormat.row(try date(2026, 12, 31, hour: 23, minute: 59)), "昨天 23:59")
        }
    }
}
