import Darwin
import Foundation

/// Coarse single-instance guard backed by an advisory file lock (`flock`).
///
/// The previous approach enumerated running apps with the same bundle id and
/// terminated peers. That races: two instances launched near-simultaneously can
/// each see the other and *both* quit. With an exclusive `flock`, exactly one
/// process can hold the lock, so the winner is unambiguous and the loser knows
/// to bow out.
///
/// The lock is held for the lifetime of the process (or until `release()`); the
/// file descriptor is intentionally kept open.
public final class SingleInstanceGuard {
    private var fileDescriptor: Int32 = -1

    public init() {}

    /// Attempts to become the primary instance for `identifier`.
    /// Returns `true` if this process acquired the lock. If the lock file can't
    /// be opened at all, it fails *open* (returns `true`) rather than blocking
    /// launch over an inability to create a lock file.
    @discardableResult
    public func acquire(identifier: String) -> Bool {
        guard fileDescriptor < 0 else { return true }

        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("\(identifier).lock")

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            // Another instance already holds the lock.
            Darwin.close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }

    /// Releases the lock. Primarily for tests; in the app the lock is meant to
    /// live as long as the process.
    public func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            Darwin.close(fileDescriptor)
        }
    }
}
