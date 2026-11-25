import Foundation

struct HistoryDatePresentation {
    private let calendar: Calendar
    private let now: Date
    private let time: DateFormatter
    private let monthDay: DateFormatter
    private let yearMonthDay: DateFormatter
    private let dateAndTime: DateFormatter

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) {
        self.now = now
        self.calendar = calendar
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        time = formatter("HHmm")
        monthDay = formatter("MMMd")
        yearMonthDay = formatter("yMd")
        dateAndTime = formatter("yMMMMdHHmmss")
    }

    func row(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.format("history.todayAt", time.string(from: date))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.format("history.yesterdayAt", time.string(from: date))
        }
        let formatter = calendar.isDate(date, equalTo: now, toGranularity: .year) ? monthDay : yearMonthDay
        return formatter.string(from: date)
    }

    func detail(_ date: Date) -> String { dateAndTime.string(from: date) }
}
