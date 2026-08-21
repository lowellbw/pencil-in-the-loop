//
//  SqueezeTrace.swift
//  AppUI · Review
//
//  TEMPORARY DIAGNOSTIC — delete with the call sites once the squeeze
//  behaviour is understood.
//
//  Writes to stderr rather than using `print`, because stdout is fully
//  buffered when it is a pipe, which is exactly what `devicectl device
//  process launch --console` gives it: a few short lines never reach the
//  4KB flush and the trace looks empty while the app is plainly reacting.
//

import Foundation

func plsq(_ message: String) {
    FileHandle.standardError.write(Data("[PL-SQ] \(message)\n".utf8))
}
