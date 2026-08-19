//
//  InkLog.swift
//  Annotate · Ink
//
//  One logger for the ink path. `print` is banned (STYLE.md § 5), and an ink
//  bug on device is almost always something you have to read out of a log
//  afterwards, because you cannot pause a Pencil.
//

import Foundation
import os

/// Loggers for the ink path.
///
/// **On failure:** logging never fails and never blocks; `Logger` drops
/// messages rather than waiting, which is the behaviour we want on a path that
/// must not stall.
enum InkLog {

    /// Reverse-DNS subsystem, matching the convention the other modules use.
    static let subsystem = "co.pencil-loop.annotate"

    /// Canvas lifecycle: binding, recycling, layout under zoom.
    static let canvas = Logger(subsystem: InkLog.subsystem, category: "ink.canvas")

    /// Autosave: debounce, writes, retries.
    static let persistence = Logger(subsystem: InkLog.subsystem, category: "ink.persistence")

    /// Handwriting recognition, which is allowed to fail quietly and often.
    static let recognition = Logger(subsystem: InkLog.subsystem, category: "ink.recognition")
}
