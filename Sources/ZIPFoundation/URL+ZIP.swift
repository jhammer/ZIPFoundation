//
//  URL+ZIP.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension URL {
    static func temporaryReplacementDirectoryURL(for archive: Archive) -> URL {
        #if swift(>=5.0) || os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        if archive.url.isFileURL,
           let tempDir = try? FileManager().url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: archive.url, create: true) {
            return tempDir
        }
        #endif

        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            ProcessInfo.processInfo.globallyUniqueString)
    }

    /// A file URL representing the root of the local filesystem (`/`).
    /// Can be used to indicate that symlinks may point anywhere on the filesystem during extraction.
    public static var rootFS: URL {
        URL(fileURLWithPath: "/")
    }

    /// Returns whether `destinationPath`, the destination of a symlink at `linkURL`, resolves inside `directoryURL`.
    ///
    /// The destination is followed from the link's parent directory as far as it currently exists, so symlinks
    /// already on disk (including ones extracted earlier from the same archive) are taken into account.
    static func isSymlinkDestination(
        _ destinationPath: String,
        ofLinkAt linkURL: URL,
        containedIn directoryURL: URL
    ) -> Bool {
        // The kernel resolves destinations starting with `/` from the root and all others (including `~/...`)
        // from the directory containing the link.
        let startPath = destinationPath.hasPrefix("/") ? "/" : linkURL.deletingLastPathComponent().path
        return URL.isPath(destinationPath, resolvedFrom: startPath, containedIn: directoryURL)
    }

    /// Returns whether `path`, followed from `startPath` through what currently exists, leads inside `directoryURL`.
    ///
    /// The file system resolves the part of `path` that exists, following symlinks and applying `..` to the
    /// directory actually reached. The rest doesn't exist yet, so where it leads depends on what gets created
    /// there. It's only accepted if it can't lead anywhere else: it must not start with a symlink (e.g. a dangling
    /// one) or contain `..`, since `missing/..` changes meaning if `missing` is later created as a symlink.
    static func isPath(_ path: String, resolvedFrom startPath: String, containedIn directoryURL: URL) -> Bool {
        guard let directoryPath = URL.realPath(directoryURL.path) else { return false }
        // Everything is inside `/` (see `rootFS`), wherever the path leads.
        guard directoryPath != "/" else { return true }
        // The file system would only see the part before a NUL.
        guard !path.contains("\0") else { return false }
        var existingPath = startPath
        var remainingComponents = path.split(separator: "/").filter { $0 != "." }.map(String.init)
        var fileStat = stat()
        while let component = remainingComponents.first, stat(existingPath + "/" + component, &fileStat) == 0 {
            existingPath += "/" + component
            remainingComponents.removeFirst()
        }
        if let component = remainingComponents.first, lstat(existingPath + "/" + component, &fileStat) == 0 {
            return false
        }
        guard !remainingComponents.contains(".."), let resolvedPath = URL.realPath(existingPath) else { return false }
        return URL.isRealPath(resolvedPath, containedIn: directoryPath)
    }

    /// Returns the absolute path `path` refers to, with all symlinks, `.` and `..` resolved by `realpath(3)`.
    static func realPath(_ path: String) -> String? {
        guard let resolvedPath = realpath(path, nil) else { return nil }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    /// Returns whether `path` is `directoryPath` or located beneath it. Both must be real paths (see `realPath`).
    static func isRealPath(_ path: String, containedIn directoryPath: String) -> Bool {
        // Compare bytes: `==` treats canonically equivalent strings (e.g. "é" and "e\u{301}") as equal, but
        // file systems like ext4 treat them as different names.
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return path.utf8.elementsEqual(directoryPath.utf8) || path.utf8.starts(with: directoryPrefix.utf8)
    }
}
