//
//  Slug.swift
//  Core · Contracts
//
//  Folder naming. Frozen here because three modules generate these names —
//  Ingest, Export and the share extension — and a folder name is an identity,
//  not a label. Two implementations that disagree about what to do with an
//  ampersand produce two documents where there should be one.
//
//  "Folder names are `YYYY-MM-DD-<slug>`. Slugs are lowercase, hyphenated,
//  ASCII." — docs/05-file-contracts.md
//

import Foundation

/// Builds and parses the folder names used throughout the sync folder.
public enum Slug {

    /// Longest slug this produces, in characters, before the date prefix.
    /// Keeps a full path comfortably inside every filesystem we might land on.
    public static let maxLength = 60

    /// Lowercase, hyphenated, ASCII.
    ///
    /// - Letters and digits pass through, lowercased.
    /// - Common accented Latin letters fold to their ASCII base (`é` → `e`),
    ///   via a canonical-decomposition pass.
    /// - Everything else becomes a hyphen; runs of hyphens collapse; leading
    ///   and trailing hyphens are trimmed.
    /// - The result is truncated to `maxLength` at a hyphen boundary where one
    ///   is available.
    /// - An input with nothing usable in it yields `"document"`, never an empty
    ///   string: a folder must have a name.
    public static func make(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var characters: [Character] = []
        for scalar in folded.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                characters.append(Character(scalar))
            } else if characters.last != "-" {
                characters.append("-")
            }
        }
        var slug = String(characters)
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > maxLength {
            let cut = String(slug.prefix(maxLength))
            if let lastHyphen = cut.lastIndex(of: "-"), cut.distance(from: cut.startIndex, to: lastHyphen) > maxLength / 2 {
                slug = String(cut[cut.startIndex..<lastHyphen])
            } else {
                slug = cut
            }
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "document" : slug
    }

    /// `2026-08-18-auth-refactor-plan`.
    ///
    /// The date is formatted in UTC so that two devices in different time zones
    /// agree about which day a document belongs to.
    public static func folderName(date: Date, title: String) -> String {
        datePrefix(for: date) + "-" + make(from: title)
    }

    /// `2026-08-18`, always UTC.
    public static func datePrefix(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return "0000-00-00" }
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Splits `2026-08-18-auth-refactor-plan` into its two halves.
    ///
    /// - Returns: nil when the name does not start with a `YYYY-MM-DD-` prefix,
    ///   which is legitimate — a user can drop a folder called anything into
    ///   `inbox/` and it still ingests.
    public static func split(folderName: String) -> (datePrefix: String, slug: String)? {
        let parts = folderName.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let year = String(parts[0])
        let month = String(parts[1])
        let day = String(parts[2])
        guard year.count == 4, month.count == 2, day.count == 2,
              year.allSatisfy(\.isNumber), month.allSatisfy(\.isNumber), day.allSatisfy(\.isNumber) else {
            return nil
        }
        return ("\(year)-\(month)-\(day)", String(parts[3]))
    }

    /// Appends `-2`, `-3`, … until the name is not in `existing`.
    ///
    /// Two documents sent the same day with the same title is normal, and
    /// silently overwriting one of them is not acceptable.
    public static func disambiguated(_ folderName: String, existing: Set<String>) -> String {
        guard existing.contains(folderName) else { return folderName }
        var counter = 2
        while existing.contains("\(folderName)-\(counter)") {
            counter += 1
        }
        return "\(folderName)-\(counter)"
    }
}
