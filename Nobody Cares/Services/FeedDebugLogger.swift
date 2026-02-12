//
//  FeedDebugLogger.swift
//  Nobody Cares
//
//  Centralized debug logging for the feed system.
//  All output is prefixed with [NC] and a subsystem tag for easy Xcode console filtering.
//
//  Subsystem tags:
//    FEED    — FeedViewModel lifecycle, state changes, navigation
//    PAGER   — FeedPagerViewController scroll, swipe, snap, page commit
//    DATA    — FeedDataService fetch, results, errors
//    MEDIA   — MediaPreloader prepare, readiness, cancel, playback
//    LOC     — LocationService movement, stationary, updates
//    RADAR   — DevRadarView coordinate calculations
//
//  Usage:
//    FeedDebugLogger.log(.feed, "startFeed called")
//    FeedDebugLogger.log(.media, "Preparing index \(idx)", detail: "type=video url=\(url)")
//
//  Toggle: Set `FeedDebugLogger.isEnabled = false` to silence all output.
//

import Foundation

enum DebugSubsystem: String {
    case feed   = "FEED"
    case pager  = "PAGER"
    case data   = "DATA"
    case media  = "MEDIA"
    case loc    = "LOC"
    case radar  = "RADAR"
    case camera = "CAM"
    case upload = "UPLOAD"
}

enum FeedDebugLogger {
    /// Master switch — set to `false` to silence all debug output.
    static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Log a debug message to the Xcode console.
    /// - Parameters:
    ///   - subsystem: The subsystem tag (e.g. `.feed`, `.pager`).
    ///   - message: Primary log message.
    ///   - detail: Optional secondary detail (printed on same line after " | ").
    static func log(_ subsystem: DebugSubsystem, _ message: String, detail: String? = nil) {
        guard isEnabled else { return }

        let timestamp = Self.formatter.string(from: Date())
        var line = "[NC:\(subsystem.rawValue)] \(timestamp) \(message)"
        if let detail {
            line += " | \(detail)"
        }
        print(line)
    }

    // MARK: - Private

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
