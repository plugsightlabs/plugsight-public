// DefinitionsAge.swift
//
// Read the age of ClamAV's signature definitions from the freshclam database
// files' modification timestamps (docs/spec/05). Older than `definitionsWarnDays`
// (default 7) records a notice ("definitions 12 days old") in scan records and in
// Settings, because a scan with stale signatures should not read as full strength.
//
// The database directory and the per-file mtime lookup are INJECTABLE so tests do
// not depend on a real freshclam install.

import Foundation

public struct DefinitionsAge {

    /// The freshclam database files whose newest mtime defines "definitions age".
    /// Both `.cvd` (packaged) and `.cld` (incrementally updated) forms are checked.
    public static let defaultFileNames = [
        "daily.cld", "daily.cvd",
        "main.cld", "main.cvd",
        "bytecode.cld", "bytecode.cvd",
    ]

    private let databaseDirectory: String
    private let fileNames: [String]
    private let mtime: (String) -> Date?

    public init(
        databaseDirectory: String,
        fileNames: [String] = DefinitionsAge.defaultFileNames,
        mtime: @escaping (String) -> Date? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
    ) {
        self.databaseDirectory = databaseDirectory
        self.fileNames = fileNames
        self.mtime = mtime
    }

    /// Age in whole days of the NEWEST definitions file, or nil when no database
    /// file is present (definitions age unknown).
    public func ageInDays(now: Date = Date()) -> Int? {
        let newest = fileNames
            .map { databaseDirectory + "/" + $0 }
            .compactMap { mtime($0) }
            .max()
        guard let newest else { return nil }
        let seconds = now.timeIntervalSince(newest)
        return Int((seconds / 86_400).rounded(.down))
    }

    /// A one-line notice string when definitions are older than `warnDays`, else
    /// nil (fresh, or unknown). Copy: "definitions N days old".
    public func notice(now: Date = Date(), warnDays: Int) -> String? {
        guard let age = ageInDays(now: now), age > warnDays else { return nil }
        return "definitions \(age) days old"
    }
}
