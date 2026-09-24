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

    /// Returns whether a symlink at the receiver pointing to `destination` resolves inside `directoryURL`.
    ///
    /// `destination` is resolved from the link's real parent directory, following any symlinks that
    /// already exist on disk (including ones extracted earlier from the same archive).
    /// The parent directory is expected to exist.
    func isSymlinkDestination(_ destination: String, containedIn directoryURL: URL) -> Bool {
        guard let directory = try? ResolvedPath(resolving: directoryURL) else { return false }
        // Everything is inside `/` (see `rootFS`), wherever the destination leads.
        guard !directory.components.isEmpty else { return true }
        guard let parent = try? ResolvedPath(resolving: self.deletingLastPathComponent()) else { return false }
        // The kernel resolves destinations starting with `/` from the root and all others (including `~/...`)
        // from the directory containing the link.
        let start = destination.hasPrefix("/") ? ResolvedPath.root : parent
        // `a -> b/../file` looks contained while `b` doesn't exist, but a later entry could create `b`
        // as a symlink to `.`, which would move the destination to `../file`.
        guard let resolved = try? start.appending(destination, options: .rejectingParentOfMissingItems) else {
            return false
        }
        return resolved.isContained(in: directory)
    }
}

/// A path resolved against the file system the way the kernel resolves it when the path is opened or created.
///
/// Components are resolved one at a time: an existing symlink is replaced by its destination (a relative
/// destination continues from the directory containing the link) and `..` steps up from the directory
/// actually reached, not from the path as written. Components that don't exist yet are kept as written.
/// Empty components are skipped like `fopen` does, so `dir//../file` means `dir/../file`
/// (see https://github.com/weichsel/ZIPFoundation/issues/281).
///
/// `URL.standardized` and `URL.resolvingSymlinksInPath()` collapse `..` lexically instead, so containment
/// checks based on them can be sidestepped by paths like `link/../file` once `link` is a symlink on disk.
struct ResolvedPath {

    struct Options: OptionSet {
        let rawValue: Int

        /// Fail instead of following an existing symlink inside the directory resolution starts from.
        static let rejectingSymlinks = Options(rawValue: 1 << 0)
        /// Fail when `..` steps out of a component that doesn't exist yet. Where such a path ends up
        /// depends on what gets created there later.
        static let rejectingParentOfMissingItems = Options(rawValue: 1 << 1)
    }

    enum ResolutionError: Error {
        case invalidPath
        case symlinkEncountered
        case parentOfMissingItem
        case tooManySymlinks
    }

    /// The root directory `/`.
    static let root = ResolvedPath()
    /// Matches `MAXSYMLINKS` on Darwin.
    static let maxSymlinkCount = 32

    /// The components of the resolved absolute path. Empty for `/`.
    private(set) var components = [String]()
    /// The number of trailing `components` that don't exist on disk.
    private var missingComponentCount = 0

    var path: String {
        return "/" + self.components.joined(separator: "/")
    }

    private init() {}

    /// Resolves the path of the file URL `url`. A relative path is resolved from the current directory.
    init(resolving url: URL) throws {
        let path = url.path
        let absolutePath = path.hasPrefix("/") ? path : FileManager().currentDirectoryPath + "/" + path
        self = try ResolvedPath.root.appending(absolutePath)
    }

    func isContained(in directory: ResolvedPath) -> Bool {
        return self.components.starts(with: directory.components)
    }

    /// Returns whether `path`, resolved from the receiver, stays inside the receiver without passing
    /// through a symlink located inside it.
    func contains(relativePath path: String) -> Bool {
        guard let resolved = try? self.appending(path, options: .rejectingSymlinks) else { return false }
        return resolved.isContained(in: self)
    }

    /// Resolves `path` starting from the receiver.
    ///
    /// `path` is always relative to the receiver; leading `/` are skipped like any empty component.
    /// Start from `ResolvedPath.root` to resolve an absolute path.
    func appending(_ path: String, options: Options = []) throws -> ResolvedPath {
        var result = self
        var pending = Array(path.split(separator: "/", omittingEmptySubsequences: false).reversed())
        var symlinkCount = 0
        while let component = pending.popLast() {
            switch component {
            case "", ".":
                continue
            case "..":
                try result.removeLastComponent(options: options)
            default:
                guard let destination = try result.appendComponent(component) else { continue }
                if options.contains(.rejectingSymlinks), result.isContained(in: self) {
                    throw ResolutionError.symlinkEncountered
                }
                symlinkCount += 1
                guard symlinkCount <= ResolvedPath.maxSymlinkCount else { throw ResolutionError.tooManySymlinks }
                // Continue with the link's destination, starting from the directory containing the link.
                result.components.removeLast()
                if destination.hasPrefix("/") { result.components.removeAll() }
                pending += destination.split(separator: "/", omittingEmptySubsequences: false).reversed()
            }
        }
        return result
    }

    private mutating func removeLastComponent(options: Options) throws {
        if self.missingComponentCount > 0 {
            guard !options.contains(.rejectingParentOfMissingItems) else { throw ResolutionError.parentOfMissingItem }
            self.missingComponentCount -= 1
        }
        _ = self.components.popLast()
    }

    /// Appends `component` and returns the destination of the resulting path if it's an existing symlink.
    private mutating func appendComponent(_ component: Substring) throws -> String? {
        // The file system would only see the part before a NUL.
        guard !component.contains("\0") else { throw ResolutionError.invalidPath }
        self.components.append(String(component))
        guard self.missingComponentCount == 0 else {
            self.missingComponentCount += 1
            return nil
        }
        var fileStat = stat()
        guard lstat(self.path, &fileStat) == 0 else {
            // Anything that can't be looked up can't be written through either, so it's treated as missing.
            self.missingComponentCount = 1
            return nil
        }
        guard fileStat.st_mode & S_IFMT == S_IFLNK else { return nil }
        return try FileManager().destinationOfSymbolicLink(atPath: self.path)
    }
}
