import Foundation

extension DateInterval {
    var weekdays: [Int] {
        let calendar = Calendar.current
        var weekdaySet = Set<Int>()
        var currentDate = start

        while currentDate < end {
            let weekday = calendar.component(.weekday, from: currentDate)
            weekdaySet.insert(weekday)
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = nextDate
        }

        return weekdaySet.sorted()
    }
}

// MARK: Data

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
