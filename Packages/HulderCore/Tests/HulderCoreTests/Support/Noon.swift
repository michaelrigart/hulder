import Foundation

/// Noon on a fixed day in the machine's calendar, plus `days` days and `seconds` seconds.
func noon(days: Int = 0, plusSeconds seconds: TimeInterval = 0) -> Date {
    let calendar = Calendar.current
    let day = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14 + days, hour: 12))!
    return day.addingTimeInterval(seconds)
}
