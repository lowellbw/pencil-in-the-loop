//
//  ReaderLog.swift
//  AppUI · Reader
//
//  One logger for the reader. `print` is banned (STYLE.md § 5), and most of what
//  goes wrong in here — an overlay asked for before a document opened, a page
//  index PDFKit will not resolve — happens on a device with a Pencil in your
//  hand, where the only record afterwards is the log.
//

import Foundation
import os

/// Loggers for the reader.
///
/// **On failure:** logging never fails and never blocks. `Logger` drops
/// messages rather than waiting, which is what we want on a path that shares a
/// run loop with ink.
enum ReaderLog {

    /// Reverse-DNS subsystem, matching the convention Annotate uses.
    static let subsystem = "co.pencil-loop.appui"

    /// Opening, closing, reading position, reading time.
    static let reader = Logger(subsystem: ReaderLog.subsystem, category: "reader")

    /// The shell: which screen is up, and which transport it settled on.
    static let shell = Logger(subsystem: ReaderLog.subsystem, category: "shell")

    /// The overlay provider and the canvas pool it drives.
    static let overlay = Logger(subsystem: ReaderLog.subsystem, category: "reader.overlay")

    /// Anchor capture and comment markers.
    static let anchor = Logger(subsystem: ReaderLog.subsystem, category: "reader.anchor")
}
