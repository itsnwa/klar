import Foundation
import os

/// Centralized logging utility with performance optimization. Logs from any
/// thread: its settings are fixed at launch.
nonisolated final class Logger: Sendable {
    
    enum Level: Int, CaseIterable {
        case verbose = 0
        case debug = 1
        case info = 2
        case warning = 3
        case error = 4
        case off = 5
        
        var emoji: String {
            switch self {
            case .verbose: return "🔍"
            case .debug: return "🔧"
            case .info: return "ℹ️"
            case .warning: return "⚠️"
            case .error: return "❌"
            case .off: return ""
            }
        }
        
        var osLogType: OSLogType {
            switch self {
            case .verbose, .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            case .off: return .fault
            }
        }
    }
    
    enum Category: String, CaseIterable {
        case sidebar = "Sidebar"
        case tabManagement = "TabManagement"
        case webView = "WebView"
        case media = "Media"
        case persistence = "Persistence"
        case dragDrop = "DragDrop"
        case general = "General"
        case commandPalette = "CommandPalette"
        case location = "Location"
        case history = "History"
        case settings = "Settings"
        case readingList = "ReadingList"
        case passwords = "Passwords"
        case extensions = "Extensions"
        case sync = "Sync"
        case updates = "Updates"

        var icon: String {
            switch self {
              case .sidebar: return "↔️"
              case .tabManagement: return "📑"
              case .webView: return "🌐"
              case .media: return "🎵"
              case .persistence: return "💾"
              case .dragDrop: return "🫳"
              case .general: return "📝"
              case .commandPalette: return "🔍"
              case .location: return "🗺️"
              case .history: return "📚"
              case .settings: return "⚙️"
              case .readingList: return "📖"
              case .passwords: return "🔑"
              case .extensions: return "🧩"
              case .sync: return "☁️"
              case .updates: return "⬆️"
            }
        }
    }
    
    static let shared = Logger()
    
    private let osLog: OSLog
    private let _isLoggingEnabled: Bool
    private let minimumLevel: Level
    
    private init() {
        self.osLog = OSLog(subsystem: "com.itsnwa.browser", category: "Klar")
        
        // Only enable verbose logging in debug builds
        #if DEBUG
        self._isLoggingEnabled = true
        self.minimumLevel = .debug  // Changed from .verbose to .debug for better performance
        #else
        // Errors only, and none from a private tab (`error(_:_:isPrivate:)`)
        self._isLoggingEnabled = true
        self.minimumLevel = .error
        #endif
    }
    
    /// High-performance logging method with early bailout
    func log(_ level: Level, category: Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        // Early bailout for performance - avoid string interpolation if logging is disabled
        guard _isLoggingEnabled && level.rawValue >= minimumLevel.rawValue else { return }
        
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "\(category.icon) [\(category.rawValue)] \(level.emoji) \(message()) - \(filename):\(function):\(line)"
        
        // The system log, which Xcode's console shows too (the scheme's
        // IDEPreferLogStreaming): printing as well showed every message twice
        os_log("%{public}@", log: osLog, type: level.osLogType, logMessage)
    }
    
    /// Convenience methods for different log levels
    func debug(_ category: Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, category: category, message(), file: file, function: function, line: line)
    }
    
    func info(_ category: Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message(), file: file, function: function, line: line)
    }
    
    func warning(_ category: Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message(), file: file, function: function, line: line)
    }
    
    /// `isPrivate`: the error comes from a page in a private tab. Release
    /// builds, which log errors only, leave it out: a private tab leaves no
    /// trace in the system log either. Debug builds log everything.
    func error(_ category: Category, _ message: @autoclosure () -> String, isPrivate: Bool = false, file: String = #file, function: String = #function, line: Int = #line) {
        #if !DEBUG
        guard !isPrivate else { return }
        #endif
        log(.error, category: category, message(), file: file, function: function, line: line)
    }
}

// MARK: - Convenience Global Functions

/// Quick access to Logger for common use cases
nonisolated func logDebug(_ category: Logger.Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.debug(category, message(), file: file, function: function, line: line)
}

nonisolated func logInfo(_ category: Logger.Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.info(category, message(), file: file, function: function, line: line)
}

nonisolated func logWarning(_ category: Logger.Category, _ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.warning(category, message(), file: file, function: function, line: line)
}

nonisolated func logError(_ category: Logger.Category, _ message: @autoclosure () -> String, isPrivate: Bool = false, file: String = #file, function: String = #function, line: Int = #line) {
    Logger.shared.error(category, message(), isPrivate: isPrivate, file: file, function: function, line: line)
}
