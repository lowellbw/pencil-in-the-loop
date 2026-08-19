//
//  ContractCoding.swift
//  Core · Contracts
//
//  The one encoder and the one decoder. Every file this app writes into the
//  sync folder goes through these, and every file it reads comes back through
//  them.
//
//  The date format, the key order and the escaping rules are part of the public
//  file contract, so they cannot be a per-call-site decision. A second
//  JSONEncoder configured slightly differently is how a fixture stops matching
//  byte for byte.
//

import Foundation

/// Frozen JSON coding for every on-disk contract type.
///
/// - Dates are ISO 8601 with a `Z` suffix and second precision, matching
///   `"createdAt": "2026-08-18T18:22:04Z"` in docs/05-file-contracts.md.
///   Parsing additionally tolerates fractional seconds and numeric offsets,
///   because other tools write those.
/// - Keys are sorted so that two runs over the same data produce identical
///   bytes, which is what makes `manifest.json` checksums meaningful.
/// - Output is pretty-printed. These files get read by humans in a diff.
/// - Slashes are not escaped — `ink/page-01.png` stays legible.
public enum ContractCoding {

    /// The encoder every writer must use.
    ///
    /// A fresh instance per call: `JSONEncoder` is not `Sendable` and a shared
    /// one would need a lock for no measurable gain — bundle writes happen once
    /// per review, not once per frame.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, dateEncoder in
            var container = dateEncoder.singleValueContainer()
            try container.encode(ContractCoding.string(from: date))
        }
        return encoder
    }

    /// The decoder every reader must use.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            if let text = try? container.decode(String.self),
               let date = ContractCoding.date(from: text) {
                return date
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date string or a Unix timestamp"
            )
        }
        return decoder
    }

    /// `2026-08-18T18:22:04Z`.
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Parses `2026-08-18T18:22:04Z`, the same with fractional seconds, and the
    /// same with a numeric UTC offset. Returns nil for anything else.
    public static func date(from string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
