import Foundation

/// Serialises the test classes that mutate the Tor state directories
/// `TorManager.shared` owns.
///
/// Those directories are a fixed path under Application Support rather than a
/// per-test sandbox, and two classes contend for it. `TorManagerPanicTests`
/// deletes the whole `bitchat/arti` tree, because proving a panic wipe leaves
/// nothing recoverable is the point of that test. That tree is where
/// `TorManagerDirectoryCacheTests` writes the marker files it then reads back.
/// Neither class is wrong alone; they cannot run at the same time.
///
/// CI runs `swift test --parallel`, which executes test classes in separate
/// processes, so a lock shared through a Swift global cannot serialise them.
/// `flock` is the smallest primitive that holds across processes.
///
/// Measured before this existed: ten `--parallel` runs of the two classes
/// together produced six failures. One read `panic left dir.sqlite3 recoverable
/// on disk`, which is a security assertion failing for scheduling reasons --
/// the most misleading way this could have surfaced in review.
///
/// The lock file is a rendezvous point only. Nothing reads its contents, and it
/// is deliberately never deleted: unlinking on release would let a waiting
/// process create a fresh inode and take an uncontended lock on that instead,
/// which is the standard way to make a lock quietly stop working.
enum TorStateDirectoryLock {

    /// Holds the lock for as long as it is alive.
    ///
    /// Release is explicit in `tearDown` so that cleanup deleting the shared
    /// directories still runs while the lock is held. `deinit` only covers a
    /// test that fails before reaching its teardown.
    final class Token {
        private var descriptor: Int32

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            release()
        }

        func release() {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    struct Unavailable: Error, CustomStringConvertible {
        let code: Int32

        var description: String {
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            return "Tor state directory test lock unavailable: \(underlying.localizedDescription)"
        }
    }

    private static let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("bitchat-tor-state-directory.lock")

    /// Blocks until no other process holds the lock.
    ///
    /// Throws rather than continuing unlocked. Running unserialised is the
    /// exact failure this type exists to prevent, and it would return as a
    /// flake in a class that looks unrelated to whatever broke the lock.
    static func acquire() throws -> Token {
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw Unavailable(code: errno) }

        // A signal delivered while blocked is not a lock failure, so retry.
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let code = errno
                close(descriptor)
                throw Unavailable(code: code)
            }
        }
        return Token(descriptor: descriptor)
    }
}
