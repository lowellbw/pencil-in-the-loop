//
//  CoordinatedFileAccess.swift
//  Sync · Support
//
//  `NSFileCoordinator`, wrapped so the rest of the module never has to
//  remember the `NSErrorPointer` dance or which of the two errors — the
//  coordinator's or the accessor's — actually happened.
//
//  Coordination is not optional here. The sync folder is a file-provider
//  folder; reading an item without coordination can hand you a placeholder
//  whose bytes are still on somebody's server, and writing without it can race
//  the provider's own uploader (docs/03-architecture.md § Folder access).
//
//  The reading options are deliberately not a parameter. Each entry point below
//  hardcodes the one set of options its job needs, so no call site can pass
//  `.withoutChanges` to a read that has to see the current bytes.
//

import Foundation
import Core

/// Every file operation this module performs on the sync folder.
///
/// **On failure:** throws whatever the accessor threw, or, when the
/// coordinator itself refused, the `NSError` it produced. Neither is
/// translated into a `PencilLoopError` here — the caller knows which of its own
/// failure cases the operation belongs to, and this type does not.
///
/// - Note: coordination is *not* the security scope. Every one of these
///   expects `FolderAccessing` to have opened the scope already.
public enum CoordinatedFileAccess {

    /// A coordinated read.
    ///
    /// For a provider-backed item the coordinator blocks until the item is
    /// materialised and hands `body` the URL to read from, which may not be the
    /// URL passed in. Always use the URL you are given.
    ///
    /// - Parameters:
    ///   - url: the item to read.
    ///   - body: runs with the read in effect; its return value is passed back.
    /// - Returns: whatever `body` returned.
    /// - Throws: the accessor's error, or the coordinator's.
    @discardableResult
    public static func read<T>(at url: URL, by body: (URL) throws -> T) throws -> T {
        var produced: T?
        var thrown: Error?
        var coordinationError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                produced = try body(readableURL)
            } catch {
                thrown = error
            }
        }

        if let thrown {
            throw thrown
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let produced else {
            throw CoordinatedFileAccess.silentFailure(at: url)
        }
        return produced
    }

    /// A coordinated write.
    ///
    /// - Parameters:
    ///   - url: the item being written.
    ///   - body: runs with the write in effect, against the URL it is given.
    /// - Throws: the accessor's error, or the coordinator's.
    public static func write(at url: URL, by body: (URL) throws -> Void) throws {
        var thrown: Error?
        var coordinationError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { writableURL in
            do {
                try body(writableURL)
            } catch {
                thrown = error
            }
        }

        if let thrown {
            throw thrown
        }
        if let coordinationError {
            throw coordinationError
        }
    }

    /// The move half of an atomic bundle write: a staging directory becomes the
    /// real one (docs/04-flows.md § F5).
    ///
    /// Coordinates both URLs at once — `.forMoving` on the source and
    /// `.forReplacing` on the destination — and brackets `body` with the
    /// `item(at:willMoveTo:)` / `item(at:didMoveTo:)` pair, which is what tells
    /// other presenters that this is one rename rather than a delete and a
    /// create. When `body` throws, the pair is closed the other way round — the
    /// item is announced as having moved back to the source, because it never
    /// left — so no presenter is left believing in a move that did not happen.
    ///
    /// - Parameters:
    ///   - source: the staging directory.
    ///   - destination: where it should land.
    ///   - body: performs the actual move, using the two URLs it is given.
    /// - Throws: the accessor's error, or the coordinator's.
    public static func move(
        from source: URL,
        to destination: URL,
        by body: (URL, URL) throws -> Void
    ) throws {
        var thrown: Error?
        var coordinationError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { movableSource, replaceableDestination in
            coordinator.item(at: movableSource, willMoveTo: replaceableDestination)
            do {
                try body(movableSource, replaceableDestination)
                coordinator.item(at: movableSource, didMoveTo: replaceableDestination)
            } catch {
                // The move did not happen, and every other presenter has already
                // been told it was about to. Announcing the reverse puts them
                // back where the filesystem actually is — the item is still at
                // the source — rather than leaving them believing in a
                // destination that was never written.
                coordinator.item(at: replaceableDestination, didMoveTo: movableSource)
                thrown = error
            }
        }

        if let thrown {
            throw thrown
        }
        if let coordinationError {
            throw coordinationError
        }
    }

    /// A coordinated delete.
    ///
    /// - Parameters:
    ///   - url: the item to remove.
    ///   - body: performs the removal against the URL it is given.
    /// - Throws: the accessor's error, or the coordinator's.
    public static func delete(at url: URL, by body: (URL) throws -> Void) throws {
        var thrown: Error?
        var coordinationError: NSError?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deletableURL in
            do {
                try body(deletableURL)
            } catch {
                thrown = error
            }
        }

        if let thrown {
            throw thrown
        }
        if let coordinationError {
            throw coordinationError
        }
    }

    /// The error used when the coordinator neither ran the accessor nor
    /// reported a reason, which should not happen and has been seen to.
    private static func silentFailure(at url: URL) -> Error {
        PencilLoopError.folderUnavailable(
            reason: "The file coordinator did not run the accessor for \(url.lastPathComponent)."
        )
    }
}
