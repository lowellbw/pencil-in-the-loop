//
//  SyncLog.swift
//  Sync · Support
//
//  The module's loggers. STYLE.md § 5 bans `print`; this is what stands in for
//  it. One category per collaborator so a folder problem and an ingest problem
//  can be filtered apart in Console.
//

import Foundation
import os

/// Sync's `os.Logger` instances, one per collaborator.
///
/// **Never fails.** Logging is best-effort by construction — nothing in this
/// module branches on whether a message was recorded.
public enum SyncLog {

    /// Reverse-DNS subsystem shared by every category.
    public static let subsystem = "co.pencil-loop.sync"

    /// Security scope, bookmarks, reachability.
    public static let folder = Logger(subsystem: subsystem, category: "folder")

    /// Inbox scanning and reply detection.
    public static let scan = Logger(subsystem: subsystem, category: "scan")

    /// Download-and-pin: materialisation and the copy into the container.
    public static let pin = Logger(subsystem: subsystem, category: "pin")

    /// The polling watcher and its `NSFilePresenter` accelerant.
    public static let watch = Logger(subsystem: subsystem, category: "watch")

    /// Outbox writes and the offline queue.
    public static let outbox = Logger(subsystem: subsystem, category: "outbox")

    /// The coordinator's own loop.
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
}
