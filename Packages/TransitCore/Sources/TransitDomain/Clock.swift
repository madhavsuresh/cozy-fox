import Foundation

/// A testable wall clock. Live impl uses `Date.now`; tests inject a `FakeClock`.
public protocol Clock: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { .now }
    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
}

public struct FakeClock: Clock {
    public var fixed: Date
    public var calendar: Calendar
    public init(_ fixed: Date, calendar: Calendar = SystemClock().calendar) {
        self.fixed = fixed
        self.calendar = calendar
    }
    public var now: Date { fixed }
}
