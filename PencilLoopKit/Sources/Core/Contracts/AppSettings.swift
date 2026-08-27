//
//  AppSettings.swift
//  Core · Contracts
//
//  Everything Settings can change (docs/02-spec.md § S6 — "deliberately
//  short"). Five types in one file; listed in tooling/lint/style_allowlist.txt.
//
//  A value type, not a store: `SettingsStoring` owns persistence. Passing the
//  whole struct around means a view that reads two settings makes one call, and
//  a preview can hand over a literal.
//

import Foundation

/// The complete user-facing configuration.
public struct AppSettings: Codable, Sendable, Hashable {

    /// Security-scoped bookmark for the sync root. Nil means first run has not
    /// happened — the app shows S0 and nothing else.
    public var syncFolderBookmark: Data?

    /// Last known display name of the sync folder, so Settings can name it
    /// without resolving the bookmark.
    public var syncFolderDisplayName: String?

    public var pageTint: PageTint

    public var ink: InkDefaults

    /// BCP-47 identifier for speech, e.g. `en-GB`. Frozen as a string rather
    /// than a `Locale` because it is persisted and must round-trip exactly.
    public var transcriptionLocaleIdentifier: String

    /// Default for the review sheet's "Inked pages" toggle.
    public var sendInkedPagesAsImages: Bool

    /// Set once S0 completes. Guards the whole first-run path.
    public var hasCompletedFirstRun: Bool

    /// Which generation of shipped ink defaults this blob has seen, or nil in
    /// one written before the stamp existed.
    ///
    /// Optional for the same reason `syncTransport` is, and read the same way:
    /// nil means "older than this field", not "unset by choice". Anything other
    /// than `InkDefaults.generation` means the shipped defaults have moved on
    /// since this blob was written, and `AppSettingsStore` resets `ink` once and
    /// stamps it.
    public var inkDefaultsGeneration: Int?

    // MARK: - The server transport
    //
    // Three Optionals, and they are Optional for a reason that is written out
    // in full above `init(from:)`. Read `transport`, never `syncTransport`.

    /// Whether `syncTransport` is a choice the user made in Settings, or nil in
    /// a blob written before anybody asked.
    ///
    /// **Recording an address is not the same as choosing a transport, and
    /// conflating the two stranded a device.** `RootModel` adopts the relay a
    /// build ships pointed at, once, for installs that predate it. It used to
    /// decide "have they already been offered this?" by asking whether
    /// `serverBaseURLString` was set — and an install that had the address
    /// recorded while sitting on `.folder` therefore looked like somebody who
    /// had considered the relay and declined it. It was not offered again, ever,
    /// and documents stopped arriving with nothing on screen to say why.
    ///
    /// So the question is asked directly instead. Nil means nobody has chosen;
    /// `true` is set only by the two Settings actions that are a choice
    /// (`SettingsModel.useFolderTransport()`, `SettingsModel.adoptServer(...)`),
    /// and a `true` here is respected for good.
    public var transportChosenByUser: Bool?

    /// Which transport carries documents, or nil in a settings blob written
    /// before the relay existed — which is every blob on every device that
    /// installed the app before this build.
    ///
    /// **When it is nil:** `transport` answers `.folder`, so an existing
    /// install keeps syncing exactly as it did yesterday.
    public var syncTransport: SyncTransport?

    /// The relay's base URL as the user typed it, e.g.
    /// `https://relay.example.com`. Nil until a server is adopted.
    ///
    /// A string rather than a `URL` because it is persisted and has to
    /// round-trip byte for byte; `serverBaseURL` is the parsed view.
    public var serverBaseURLString: String?

    /// Last known display name for the server, so Settings can name it without
    /// showing a URL.
    ///
    /// **When it is nil:** there is nothing friendlier to show and the caller
    /// falls back to the host from `serverBaseURL`.
    public var serverDisplayName: String?

    // MARK: - Grouping

    /// Which group each document is filed under, or nil in a blob written
    /// before groups existed — which is every blob on every device that
    /// installed the app before this build.
    ///
    /// **Read `groups`, never this.** Optional for the same reason
    /// `syncTransport` is, and nil and empty mean the same thing to every
    /// caller: nothing has been filed.
    public var documentGroups: DocumentGroups?

    public init(
        syncFolderBookmark: Data? = nil,
        syncFolderDisplayName: String? = nil,
        pageTint: PageTint = .none,
        ink: InkDefaults = .standard,
        transcriptionLocaleIdentifier: String = AppSettings.defaultTranscriptionLocaleIdentifier,
        sendInkedPagesAsImages: Bool = true,
        hasCompletedFirstRun: Bool = false,
        inkDefaultsGeneration: Int? = InkDefaults.generation,
        transportChosenByUser: Bool? = nil,
        syncTransport: SyncTransport? = nil,
        serverBaseURLString: String? = nil,
        serverDisplayName: String? = nil,
        documentGroups: DocumentGroups? = nil
    ) {
        self.syncFolderBookmark = syncFolderBookmark
        self.syncFolderDisplayName = syncFolderDisplayName
        self.pageTint = pageTint
        self.ink = ink
        self.transcriptionLocaleIdentifier = transcriptionLocaleIdentifier
        self.sendInkedPagesAsImages = sendInkedPagesAsImages
        self.hasCompletedFirstRun = hasCompletedFirstRun
        self.inkDefaultsGeneration = inkDefaultsGeneration
        self.transportChosenByUser = transportChosenByUser
        self.syncTransport = syncTransport
        self.serverBaseURLString = serverBaseURLString
        self.serverDisplayName = serverDisplayName
        self.documentGroups = documentGroups
    }

    /// A fresh install.
    public static let initial = AppSettings()

    /// British English. The app's own spelling is British throughout; the
    /// default recogniser locale should match what the user is most likely
    /// dictating.
    public static let defaultTranscriptionLocaleIdentifier = "en-GB"

    /// `transcriptionLocaleIdentifier` as a `Locale`, for the transcriber.
    public var transcriptionLocale: Locale {
        Locale(identifier: transcriptionLocaleIdentifier)
    }

    /// The transport in force.
    ///
    /// **When `syncTransport` is absent or unreadable:** `.folder`. Every
    /// install that predates the relay lands here, and so does any settings
    /// blob a future build writes a transport this build has never heard of.
    public var transport: SyncTransport {
        syncTransport ?? .folder
    }

    /// The groups in force.
    ///
    /// **When `documentGroups` is absent or unreadable:** empty. A blob that
    /// predates grouping reads as nothing filed rather than as a failure, and
    /// so does one a future build wrote in a shape this build cannot read.
    public var groups: DocumentGroups {
        documentGroups ?? .empty
    }

    /// `serverBaseURLString`, parsed.
    ///
    /// **When it fails:** nil — the string is absent, empty, or not a URL. Nil
    /// means the server transport has nowhere to talk to, and the recovery is
    /// to put the user back in front of the server form. It does not check the
    /// scheme: rejecting `http://` happens in one function on the way in, not
    /// on every read of this property.
    public var serverBaseURL: URL? {
        guard let serverBaseURLString, serverBaseURLString.isEmpty == false else { return nil }
        return URL(string: serverBaseURLString)
    }

    // MARK: - Codable

    /// The keys this struct is persisted under. Named explicitly so that
    /// `init(from:)` below cannot drift away from a synthesised set.
    private enum CodingKeys: String, CodingKey {
        case syncFolderBookmark
        case syncFolderDisplayName
        case pageTint
        case ink
        case transcriptionLocaleIdentifier
        case sendInkedPagesAsImages
        case hasCompletedFirstRun
        case inkDefaultsGeneration
        case transportChosenByUser
        case syncTransport
        case serverBaseURLString
        case serverDisplayName
        case documentGroups
    }

    /// Decodes settings written by *any* build of this app, including one that
    /// had never heard of the field you are about to add.
    ///
    /// ─── READ THIS BEFORE ADDING A FIELD ─────────────────────────────────────
    /// `AppSettingsStore.load` catches every decode failure and falls back to
    /// `AppSettings.initial` — `hasCompletedFirstRun == false`, no bookmark —
    /// which throws the user back to the first-run picker and loses the folder
    /// they chose. Swift's synthesised `Codable` does **not** apply a property
    /// default when a key is absent from the blob, so a single new
    /// non-Optional field would do exactly that to every existing install, on
    /// upgrade, silently.
    ///
    /// So: every new field is Optional, and every field — old ones included —
    /// is read with `decodeIfPresent` and a fallback. Nothing in here can throw
    /// on an absent key, which is the whole point.
    /// ─────────────────────────────────────────────────────────────────────────
    ///
    /// **When it fails:** only if the blob is not a JSON object at all, which
    /// `AppSettingsStore` reports and recovers from by starting fresh.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            syncFolderBookmark: try container.decodeIfPresent(Data.self, forKey: .syncFolderBookmark),
            syncFolderDisplayName: try container.decodeIfPresent(String.self, forKey: .syncFolderDisplayName),
            pageTint: try container.decodeIfPresent(PageTint.self, forKey: .pageTint) ?? .none,
            ink: try container.decodeIfPresent(InkDefaults.self, forKey: .ink) ?? .standard,
            transcriptionLocaleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .transcriptionLocaleIdentifier
            ) ?? AppSettings.defaultTranscriptionLocaleIdentifier,
            sendInkedPagesAsImages: try container.decodeIfPresent(
                Bool.self,
                forKey: .sendInkedPagesAsImages
            ) ?? true,
            hasCompletedFirstRun: try container.decodeIfPresent(
                Bool.self,
                forKey: .hasCompletedFirstRun
            ) ?? false,
            // Genuinely nil for a blob written before the stamp existed, and
            // that is the signal the reset reads — so no `?? generation`
            // default here, which would erase exactly the case it detects.
            inkDefaultsGeneration: try container.decodeIfPresent(Int.self, forKey: .inkDefaultsGeneration),
            // Nil is the answer for every install that predates the question,
            // and it is the answer that lets the relay be offered once.
            transportChosenByUser: try container.decodeIfPresent(
                Bool.self,
                forKey: .transportChosenByUser
            ),
            syncTransport: try container.decodeIfPresent(SyncTransport.self, forKey: .syncTransport),
            serverBaseURLString: try container.decodeIfPresent(String.self, forKey: .serverBaseURLString),
            serverDisplayName: try container.decodeIfPresent(String.self, forKey: .serverDisplayName),
            // `try?` on top of the rule above, because this is the one field
            // holding a collection: a `documentGroups` of the wrong shape is the
            // likeliest malformed value in the blob, and the box above says what
            // a throw here would cost. `DocumentGroups.init(from:)` cannot throw
            // either; this is the second of the two locks.
            documentGroups: try? container.decodeIfPresent(DocumentGroups.self, forKey: .documentGroups)
        )
    }
}

// MARK: - Grouping

extension AppSettings {

    /// Which group each document has been filed under, keyed by the document's
    /// `folderName` (docs/02-spec.md § S1).
    ///
    /// **A map in the settings blob rather than a column on `Document`.** An
    /// attribute on the library store would have cost a `LibrarySchemaV2` and a
    /// migration of a store holding somebody's annotations — read
    /// `Storage/Schema/LibraryMigrationPlan.swift`, which prices that — to buy
    /// one nullable string. Nothing needs a group to be queryable: the sidebar
    /// re-sections rows it has already fetched, exactly as it does for pinning.
    /// The honest cost is that document state now lives in two places, and the
    /// seam is `LibraryModel.apply(_:)`, which is the only thing that fills
    /// `DocumentSummary.groupName` in.
    ///
    /// **Keyed by `folderName`, not by the document's `UUID`.** `folderName` is
    /// what a re-sent document keeps — `DocumentStoring.upsert` matches on it —
    /// so a document that arrives twice stays where it was filed.
    ///
    /// A group has no existence apart from the documents in it. A name nothing
    /// is filed under is not a group, so there is no registry, nothing to
    /// create and nothing to delete.
    public struct DocumentGroups: Codable, Sendable, Hashable {

        /// `folderName` to the group's display name, spelled as it was first
        /// written.
        public private(set) var assignments: [String: String]

        /// The order the sidebar draws the groups in, as `key(for:)` values.
        ///
        /// **Keys rather than display names, so a rename does not lose the
        /// place.** A group the reader has never dragged is not in here at all;
        /// `orderedNames` puts those after the ones that are, alphabetically, so
        /// a new group appears somewhere predictable rather than at a position
        /// nobody chose.
        public private(set) var order: [String]

        public init(assignments: [String: String] = [:], order: [String] = []) {
            self.assignments = assignments
            self.order = order
        }

        /// Nothing filed. A fresh install, and what an unreadable blob degrades
        /// to.
        public static let empty = DocumentGroups()

        /// The longest a group name may be.
        ///
        /// A section header on an iPad sidebar truncates well before this; the
        /// cap is here so that a pasted paragraph cannot become a group. The
        /// same number as the MCP server's `MAX_GROUP_CHARS`, so both ends of
        /// the wire agree on what a name is.
        public static let maximumNameCharacters = 64

        // MARK: - Names

        /// A name with its whitespace tidied, or nil for anything that is not a
        /// usable name.
        ///
        /// **Nil is not an error.** Every caller reads it as "no group": a blank
        /// text field, a name of nothing but spaces, and an absent `meta.json`
        /// key all mean the same thing, and treating one of them as a failure
        /// would make an empty field throw.
        ///
        /// An over-long name is shortened rather than refused. A sender that
        /// ignores the documented cap should cost the user a truncated section
        /// heading, which is visible and fixable, rather than a document that
        /// silently arrives ungrouped with nothing on screen to explain it.
        public static func normalised(_ name: String?) -> String? {
            guard let name else { return nil }
            let collapsed = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard collapsed.isEmpty == false else { return nil }
            let hasControlCharacter = collapsed.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
            }
            guard hasControlCharacter == false else { return nil }
            guard collapsed.count > DocumentGroups.maximumNameCharacters else { return collapsed }
            return String(collapsed.prefix(DocumentGroups.maximumNameCharacters))
        }

        /// The key two names are compared by: case, accents and punctuation
        /// ignored, so "Attention Papers", "attention papers" and
        /// "Attention-Papers" are one group.
        ///
        /// It folds rather than transliterating, so a name in a script with no
        /// ASCII form keeps its own key instead of collapsing into one group
        /// with every other such name.
        ///
        /// **Never written into `meta.json`.** It is derivable, and a derived
        /// field in a public contract is a field that goes stale the day the
        /// rule changes (docs/05-file-contracts.md).
        public static func matchingKey(for name: String) -> String {
            let folded = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            )
            return folded
                .split { $0.isLetter == false && $0.isNumber == false }
                .joined(separator: " ")
        }

        // MARK: - Reading

        /// The group this document is filed under, or nil for Ungrouped.
        public func name(forFolderName folderName: String) -> String? {
            assignments[folderName]
        }

        /// Every group in use, alphabetically.
        ///
        /// One entry per group, not per spelling: if a hand-edited blob has both
        /// "Attention Papers" and "attention papers", they are one group and the
        /// list says so once.
        public var sortedNames: [String] {
            var firstSpellings: [String: String] = [:]
            for name in assignments.values where firstSpellings[DocumentGroups.matchingKey(for: name)] == nil {
                firstSpellings[DocumentGroups.matchingKey(for: name)] = name
            }
            return firstSpellings.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        /// Every group in use, in the order the sidebar draws them: the ones the
        /// reader has placed, in that order, then everything else alphabetically.
        ///
        /// A group named in `order` but no longer used simply does not appear —
        /// the order is a preference about groups, not a list of them, so it
        /// costs nothing to keep a stale entry and everything to have pruning it
        /// lose a place the reader chose.
        public var orderedNames: [String] {
            var remaining: [String: String] = [:]
            for name in sortedNames {
                remaining[DocumentGroups.matchingKey(for: name)] = name
            }
            var placed: [String] = []
            for key in order {
                guard let name = remaining.removeValue(forKey: key) else { continue }
                placed.append(name)
            }
            let rest = remaining.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return placed + rest
        }

        /// Draws the groups in exactly this order, first to last.
        ///
        /// Names that are not in use are still recorded: dragging a group and
        /// then emptying it and filling it again should put it back where it was
        /// put, not back in the alphabet.
        public func reordering(_ names: [String]) -> DocumentGroups {
            var keys: [String] = []
            for name in names {
                let key = DocumentGroups.matchingKey(for: name)
                guard key.isEmpty == false, keys.contains(key) == false else { continue }
                keys.append(key)
            }
            // Anything previously placed and not named this time keeps its
            // relative place at the end, so reordering a filtered view of the
            // groups does not silently discard the rest of the arrangement.
            let carried = order.filter { keys.contains($0) == false }
            return DocumentGroups(assignments: assignments, order: keys + carried)
        }

        // MARK: - Writing

        /// Files a document under `name`, or clears its group when `name` is nil.
        ///
        /// A name matching a group already in use joins that group under the
        /// spelling already on screen, so typing "attention papers" does not
        /// open a second section beside "Attention Papers".
        public func setting(_ name: String?, forFolderName folderName: String) -> DocumentGroups {
            var next = assignments
            if let wanted = DocumentGroups.normalised(name) {
                next[folderName] = existingSpelling(matching: wanted) ?? wanted
            } else {
                next.removeValue(forKey: folderName)
            }
            return DocumentGroups(assignments: next, order: order)
        }

        /// Files a document under `name` **only when it has no group already**,
        /// and does nothing at all when `name` is nil.
        ///
        /// This is what a sender's `meta.json` gets. It may propose a group for
        /// a document arriving for the first time; it may never move one the
        /// user has filed by hand, and it can never un-group anything — a
        /// re-sent document with no `group` key must not empty the section the
        /// user put it in (docs/06-integrations.md).
        public func adopting(_ name: String?, forFolderName folderName: String) -> DocumentGroups {
            guard assignments[folderName] == nil else { return self }
            guard DocumentGroups.normalised(name) != nil else { return self }
            return setting(name, forFolderName: folderName)
        }

        /// Renames a group, moving every document filed under it.
        ///
        /// Renaming onto a name already in use **merges** the two, which is the
        /// only coherent answer when a group *is* its name: there is no second
        /// identity for the two of them to disagree about.
        ///
        /// A name nothing is filed under is not an error — there is simply
        /// nothing to move — and a new name that normalises to nothing leaves
        /// everything where it is rather than un-grouping it.
        public func renaming(_ name: String, to newName: String) -> DocumentGroups {
            guard let target = DocumentGroups.normalised(newName) else { return self }
            let wanted = DocumentGroups.matchingKey(for: name)
            var next = assignments
            for (folderName, current) in assignments where DocumentGroups.matchingKey(for: current) == wanted {
                next[folderName] = target
            }
            // The order is keyed, and a rename changes the key — so it has to be
            // carried across, or renaming a group silently sends it back to the
            // alphabet. A rename that merges collapses two entries into one,
            // which is why this dedupes rather than mapping in place.
            let targetKey = DocumentGroups.matchingKey(for: target)
            var nextOrder: [String] = []
            for key in order {
                let carried = key == wanted ? targetKey : key
                guard nextOrder.contains(carried) == false else { continue }
                nextOrder.append(carried)
            }
            return DocumentGroups(assignments: next, order: nextOrder)
        }

        /// Drops assignments for documents the library no longer holds.
        ///
        /// Pass `DocumentStoring.knownFolderNames()`, which includes archived
        /// documents: archiving must not lose a group, and purging must.
        public func pruned(keeping folderNames: Set<String>) -> DocumentGroups {
            DocumentGroups(assignments: assignments.filter { folderNames.contains($0.key) }, order: order)
        }

        private func existingSpelling(matching name: String) -> String? {
            let wanted = DocumentGroups.matchingKey(for: name)
            return assignments.values.sorted().first { DocumentGroups.matchingKey(for: $0) == wanted }
        }

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case assignments
            case order
        }

        /// Decodes a group map written by *any* build, including one that had
        /// never heard of the field.
        ///
        /// **Never throws, and that is the whole point.** `AppSettingsStore.load`
        /// answers a decode failure with `AppSettings.initial` — no bookmark,
        /// and the user is back on the first-run picker having lost the folder
        /// they chose. `decodeIfPresent` throws on a *type* mismatch and not
        /// only on an absent key, so a `documentGroups` written in a shape this
        /// build cannot read would cost the user their sync folder rather than
        /// their groups. Anything unusable reads as `.empty` instead.
        public init(from decoder: Decoder) throws {
            // `try?` flattens, so an absent key and an unreadable one both land
            // in the same place — which is what this wants: either way there is
            // nothing filed.
            guard let container = try? decoder.container(keyedBy: CodingKeys.self),
                  let assignments = try? container.decodeIfPresent([String: String].self, forKey: .assignments)
            else {
                self.init()
                return
            }
            // Same two locks as `assignments`: an unreadable order costs the
            // arrangement, never the sync folder.
            let order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
            self.init(assignments: assignments, order: order)
        }
    }
}


/// Which transport carries documents to and from this iPad.
///
/// Two transports, one library. The folder is the reference transport and the
/// only one that works with no network at all; the relay is opt-in and carries
/// the same bytes (docs/12-relay.md). Switching between them never touches
/// `syncFolderBookmark`, so coming back to the folder costs nothing.
public enum SyncTransport: String, Codable, Sendable, CaseIterable, Hashable {

    /// A folder the user picked, shared by whatever file provider they like.
    case folder

    /// The hosted relay, reached over HTTPS with a bearer token.
    case server

    /// The name the Settings picker shows, alongside every other vocabulary in
    /// this file.
    public var displayName: String {
        switch self {
        case .folder: return "Folder"
        case .server: return "Server"
        }
    }
}

/// Page background wash in the reader.
///
/// Not a hex value in sight: each case maps to a system-derived colour in the UI
/// layer (docs/01-design-principles.md § 1). Core names the choice, AppUI knows
/// what it looks like.
///
/// **There is no Night, and that is a decision rather than an omission.** The
/// four cases here are White (`none`), Cream, Sepia and Grey. docs/01 asked for
/// Books' four — White, Sepia, Gray, Night — and Night is the one that cannot
/// be built the way the same rule requires: the wash is a multiply-blended
/// rectangle over the rendered page (`ReaderTintWash`), multiply can only
/// darken, and darkening a white page towards black takes the black text with
/// it. Every alternative — inverting the raster, a difference or exclusion
/// blend, `colorInvert()` — is inversion under another name, which rule 9
/// forbids for good reasons: it turns figures into negatives and
/// syntax-highlighted code into a colour scheme nobody chose, and it makes
/// graphite ink invisible on the page it was drawn on. docs/01 § 9 is corrected
/// to match, and docs/11 carries what a real Night would cost. Adding a case
/// here is a change request to the lead, and `ReaderTintWash.wash(for:)`
/// switches exhaustively so it fails visibly, in one place, if one ever lands.
public enum PageTint: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case cream
    case sepia
    case grey

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .cream: return "Cream"
        case .sepia: return "Sepia"
        case .grey: return "Grey"
        }
    }
}

/// What the tool picker starts with.
public struct InkDefaults: Codable, Sendable, Hashable {

    public var tool: InkToolKind

    /// Stroke width in points.
    public var widthPoints: Double

    /// Ink colour as `#RRGGBB`. The one hex value the design principles allow —
    /// ink belongs to the user, not to the brand (docs/01-design-principles.md
    /// § 2).
    public var tintHex: String

    /// The finest stroke the app offers, and what a document opens on.
    ///
    /// Matches `InkToolFactory.minimumWidthPoints`, which is where the number
    /// is enforced; it is repeated here because Core does not import PencilKit
    /// and cannot read it. If that constant moves, this follows it.
    /// PencilKit clamps to its own floor per ink type regardless, so asking for
    /// the finest is always safe.
    public static let finestWidthPoints: Double = 1

    /// Bumped whenever the shipped defaults change in a way that should reach
    /// installs that already have a saved value.
    ///
    /// A stored blob whose `AppSettings.inkDefaultsGeneration` is not this gets
    /// its ink reset once, in `AppSettingsStore.load(suiteName:)`, and is then
    /// left alone — so a deliberate choice made after the reset still sticks.
    public static let generation = 1

    public init(
        tool: InkToolKind = .pen,
        widthPoints: Double = InkDefaults.finestWidthPoints,
        tintHex: String = "#1C1C1E"
    ) {
        self.tool = tool
        self.widthPoints = widthPoints
        self.tintHex = tintHex
    }

    public static let standard = InkDefaults()
}

/// Which PencilKit tool to select on open.
///
/// Named cases rather than `PKInkingTool.InkType`, because Core does not import
/// PencilKit. Annotate maps these to the real tools in one place.
public enum InkToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pen
    case pencil
    case marker
    case monoline
    case highlighter

    /// The name the Settings picker shows, alongside every other vocabulary in
    /// this file and in Identifiers.swift. It lived in `SettingsView` as a
    /// local `switch`, which is one more place for five strings to drift.
    public var displayName: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .marker: return "Marker"
        case .monoline: return "Monoline"
        case .highlighter: return "Highlighter"
        }
    }
}
