// QuarantineRestore.swift  (NQR — owner ruling D6)
//
// The REVERSE of N7's `Quarantine.contain`: move a quarantined file back to its
// original location. A quarantined file lives in the quarantine directory named
// by the hex SHA-256 of its contents (the "quarantineId"), with a JSON sidecar
// (`<id>.json`) carrying original_path / scan_id / signature / device. Restoring
// reads that sidecar, moves the file back, and empties the slot (file + sidecar).
//
// Security (02, mirrored from contain): "path canonicalization before any file
// operation, quarantine moves never follow symlinks." The destination is the
// attacker-influenced side here — a malicious volume can, between quarantine and
// restore, replace the original location with a symlink pointing at a precious
// file. Following it would let a restore overwrite an unrelated file. So we
// canonicalize the destination PARENT with realpath, re-attach the leaf WITHOUT
// following it, and refuse (never overwrite, never follow) if the leaf is a
// symlink or a file already sits there. Restore only ever creates a new file at
// the canonicalized original path.

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Why a restore could not be performed. The API layer maps these onto
/// `not_found` (unknown id) / `conflict` (already restored, destination taken,
/// unsafe destination) with the state riding in the error `data`.
public enum RestoreError: Error, Equatable {
    /// No quarantine file + sidecar for this id (unknown id, or already
    /// restored/purged — the filesystem cannot tell the two apart; the API layer
    /// disambiguates with the store record).
    case notFound
    /// A file already exists at the original location; restore never overwrites.
    case destinationExists(path: String)
    /// The original location is now a symlink; following it could clobber an
    /// unrelated file, so we refuse.
    case unsafeDestination(path: String)
    /// The move itself failed (e.g. the original volume is gone or read-only).
    case moveFailed(String)
}

/// The record recovered from a successful restore: where the file went back to,
/// and the finding metadata read from the sidecar.
public struct RestoreMoveResult: Equatable, Sendable {
    public let quarantineId: String
    /// The canonicalized original path the file was restored to.
    public let originalPath: String
    public let signature: String
    public let scanID: String
    public let deviceID: String?
}

public struct QuarantineRestore {

    private let directory: String
    private let fileManager: FileManager

    public init(directory: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Restore one quarantined file to its original path and empty the slot.
    public func restore(quarantineId: String) throws -> RestoreMoveResult {
        let quarantineFile = (directory as NSString).appendingPathComponent(quarantineId)
        let sidecarPath = quarantineFile + ".json"

        // 1. Both the quarantined file and its sidecar must be present. If either
        //    is gone the slot is empty (unknown id, or already restored/purged).
        guard fileManager.fileExists(atPath: sidecarPath),
              fileManager.fileExists(atPath: quarantineFile) else {
            throw RestoreError.notFound
        }

        // 2. The quarantined file must be a regular file we own — never follow a
        //    symlink planted inside the quarantine dir.
        var qst = stat()
        guard lstat(quarantineFile, &qst) == 0, (qst.st_mode & S_IFMT) == S_IFREG else {
            throw RestoreError.notFound
        }

        // 3. Read the sidecar for the original destination + finding metadata.
        let sidecar = try Self.readSidecar(sidecarPath)
        guard let originalPath = sidecar.originalPath else {
            throw RestoreError.notFound
        }

        // 4. Canonicalize the destination PARENT, re-attach the leaf WITHOUT
        //    following it. This defeats a symlinked parent too.
        let parent = (originalPath as NSString).deletingLastPathComponent
        let leaf = (originalPath as NSString).lastPathComponent
        let canonicalParent = Self.canonicalize(parent) ?? parent
        let safeDestination = (canonicalParent as NSString).appendingPathComponent(leaf)

        // 5. lstat the destination (no-follow): refuse a symlink, refuse if it
        //    already exists. Restore never follows and never overwrites.
        var dst = stat()
        if lstat(safeDestination, &dst) == 0 {
            if (dst.st_mode & S_IFMT) == S_IFLNK {
                throw RestoreError.unsafeDestination(path: safeDestination)
            }
            throw RestoreError.destinationExists(path: safeDestination)
        }

        // 6. Move the file back, then delete the sidecar — the slot is emptied.
        do {
            try fileManager.moveItem(atPath: quarantineFile, toPath: safeDestination)
        } catch {
            throw RestoreError.moveFailed("\(error)")
        }
        try? fileManager.removeItem(atPath: sidecarPath)

        return RestoreMoveResult(
            quarantineId: quarantineId,
            originalPath: safeDestination,
            signature: sidecar.signature ?? "",
            scanID: sidecar.scanID ?? "",
            deviceID: sidecar.deviceID
        )
    }

    // MARK: - Sidecar

    private struct Sidecar {
        let originalPath: String?
        let scanID: String?
        let signature: String?
        let deviceID: String?
    }

    private static func readSidecar(_ path: String) throws -> Sidecar {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Sidecar(
            originalPath: obj["original_path"] as? String,
            scanID: obj["scan_id"] as? String,
            signature: obj["signature"] as? String,
            deviceID: obj["device"] as? String
        )
    }

    /// Resolve a path to its canonical form (symlinks and `..` collapsed), or nil
    /// if it does not resolve. Wraps POSIX `realpath(3)`.
    private static func canonicalize(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
