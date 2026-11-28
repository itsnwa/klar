import SwiftUI
import Foundation
import WebKit
import AppKit

enum TabCloseAction: String, CaseIterable {
    case never = "Never"
    case endOfDay = "End of Day"
    case after24Hours = "After 24 hours of inactivity"
    case whenClosingApp = "When Closing App"
}

enum DefaultSearchEngine: String, CaseIterable {
    case duckduckgo = "DuckDuckGo"
    case google = "Google"
    case bing = "Bing"
    case yahoo = "Yahoo"
    /// The search address in Settings › Search
    /// (`TOMLSettingsManager.customSearchEngineURL`).
    case custom = "Custom"
}

enum AppearanceMode: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"
}

/// Settings › General › Privacy: which tabs get all of Safari's Advanced Tracking and Fingerprinting Protection
/// (`TrackerBlocker.setProtections`), as Safari's "in Private Browsing" and "in all browsing".
enum FingerprintingProtection: String, CaseIterable {
    case privateTabs = "In private tabs"
    case allTabs = "In all tabs"
}

/// Settings › General › Privacy: how long history is kept, and the default.
enum HistoryRetention: String, CaseIterable {
    case oneDay = "After one day"
    case oneWeek = "After one week"
    case twoWeeks = "After two weeks"
    case oneMonth = "After one month"
    case oneYear = "After one year"
    case manually = "Manually"

    /// Visits from before this are removed; nil keeps them until they're
    /// removed by hand.
    func cutoffDate(from now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .oneDay: return calendar.date(byAdding: .day, value: -1, to: now)
        case .oneWeek: return calendar.date(byAdding: .day, value: -7, to: now)
        case .twoWeeks: return calendar.date(byAdding: .day, value: -14, to: now)
        case .oneMonth: return calendar.date(byAdding: .month, value: -1, to: now)
        case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
        case .manually: return nil
        }
    }
}
