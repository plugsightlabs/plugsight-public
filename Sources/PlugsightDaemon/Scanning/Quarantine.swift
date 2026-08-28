// Quarantine.swift
//
// Move an infected file into the quarantine directory (docs/spec/02, 05):
//   ~/Library/Application Support/Plugsight/quarantine/  (mode 0700)
// The file is renamed to the hex SHA-256 of its contents, with a JSON sidecar
// (original path, device, scan id, signature name) written alongside it.
//
// Security (02): "path canonicalization before any file operation, quarantine
// moves never follow symlinks." A malicious volume can plant a symlink named
// like an infected file and point it at a precious file elsewhere; following it
// to "contain" the finding would move the victim's file out. So we canonicalize
// the parent directory and refuse to follow a symlinked entry, degrading to
// report-only (the target is left untouched). A move that fails because the
// source volume is read-only likewise degrades to report-only.

import Foundation
import CryptoKit

public struct Quarantine {

    private let directory: String
    private let fileManager: FileManager

    public init(directory: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Contain one infected file. Never throws for the expected degrade paths
    /// (symlink, read-only volume) — those return `.reportedOnly`. It throws only
    /// on unexpected I/O errors (e.g. cannot create the quarantine directory, or
    /// cannot read a regular source file).
    public func contain(
        filePath: String,
        signature: String,
        deviceID: String?,
        scanID: String,
        now: Date = Date()
    ) throws -> QuarantineResult {
        // 1. Canonicalize the parent, then re-attach the final component WITHOUT
        //    following it. This defeats a symlinked parent directory too.
        let parent = (filePath as NSString).deletingLastPathComponent
        let leaf = (filePath as NSString).lastPathComponent
        let canonicalParent = canonicalize(parent) ?? parent
        let safePath = (canonicalParent as NSString).appendingPathComponent(leaf)

        // 2. lstat (no-follow): a symlinked entry is never followed.
        var st = stat()
        guard lstat(safePath, &st) == 0 else {
            // Source vanished between scan and containment; nothing to move.
            return .reportedOnly(reason: .readOnlyVolume)
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            return .reportedOnly(reason: .unsafeSymlink)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            // Not a regular file (dir, socket, device...): do not attempt to move.
            return .reportedOnly(reason: .unsafeSymlink)
        }

        // 3. Ensure the quarantine directory exists and is 0700.
        try ensureQuarantineDirectory()

        // 4. Hash the real file contents to derive the quarantine name.
        let data = try Data(contentsOf: URL(fileURLWithPath: safePath), options: [.mappedIfSafe])
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = (directory as NSString).appendingPathComponent(hex)

        // 5. Move the file in. A failure here (read-only source volume) degrades
        //    to report-only; we do not leave a partial copy behind.
        do {
            if fileManager.fileExists(atPath: destination) {
                // Same bytes already quarantined (identical file seen before):
                // remove the source to complete containment.
                try fileManager.removeItem(atPath: safePath)
            } else {
                try fileManager.moveItem(atPath: safePath, toPath: destination)
            }
        } catch {
            try? fileManager.removeItem(atPath: destination)
            return .reportedOnly(reason: .readOnlyVolume)
        }

        // 6. Write the sidecar next to the quarantined file.
        try writeSidecar(
            for: destination,
            originalPath: filePath,
            deviceID: deviceID,
            scanID: scanID,
            signature: signature,
            now: now
        )

        return .quarantined(path: destination)
    }

    // MARK: - Helpers

    private func ensureQuarantineDirectory() throws {
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            // Enforce 0700 even if it pre-existed with looser bits.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }
    }

    private func writeSidecar(
        for destination: String,
        originalPath: String,
        deviceID: String?,
        scanID: String,
        signature: String,
        now: Date
    ) throws {
        var sidecar: [String: Any] = [
            "v": 1,
            "original_path": originalPath,
            "scan_id": scanID,
            "signature": signature,
            "quarantined_at": ScanTime.string(now),
        ]
        sidecar["device"] = deviceID as Any? ?? NSNull()
        let json = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
        try json.write(to: URL(fileURLWithPath: destination + ".json"))
    }
}

/// Resolve a path to its canonical form (symlinks and `..` collapsed), or nil if
/// it does not resolve. Wraps POSIX `realpath(3)`.
private func canonicalize(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
