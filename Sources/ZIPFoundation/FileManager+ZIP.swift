//
//  FileManager+ZIP.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import Foundation

extension FileManager {

    typealias CentralDirectoryStructure = Entry.CentralDirectoryStructure

    /// Zips the file or directory contents at the specified source URL to the destination URL.
    ///
    /// If the item at the source URL is a directory, the directory itself will be
    /// represented within the ZIP `Archive`. Calling this method with a directory URL
    /// `file:///path/directory/` will create an archive with a `directory/` entry at the root level.
    /// You can override this behavior by passing `false` for `shouldKeepParent`. In that case, the contents
    /// of the source directory will be placed at the root of the archive.
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing file or directory.
    ///   - destinationURL: The file URL that identifies the destination of the zip operation.
    ///   - shouldKeepParent: Indicates that the directory name of a source item should be used as root element
    ///                       within the archive. Default is `true`.
    ///   - compressionMethod: Indicates the `CompressionMethod` that should be applied.
    ///                        By default, `zipItem` will create uncompressed archives.
    ///   - progress: A progress object that can be used to track or cancel the zip operation.
    ///   - preservesAppleMetadata: On Darwin platforms, store extended attributes and resource forks
    ///                             in parallel `__MACOSX/.../._<name>` AppleDouble entries (the same
    ///                             convention Archive Utility and `ditto --sequesterRsrc` produce).
    ///                             Has no effect on non-Darwin platforms, where source files do not
    ///                             carry macOS-specific metadata. Default is `true`.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    public func zipItem(at sourceURL: URL, to destinationURL: URL,
                        shouldKeepParent: Bool = true, compressionMethod: CompressionMethod = .none,
                        progress: Progress? = nil,
                        preservesAppleMetadata: Bool = true) throws {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: sourceURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        guard !fileManager.itemExists(at: destinationURL) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        let archive = try Archive(url: destinationURL, accessMode: .create)
        let isDirectory = try FileManager.typeForItem(at: sourceURL) == .directory
        if isDirectory {
            var subPaths = try self.subpathsOfDirectory(atPath: sourceURL.path)
            // Enforce an entry for the root directory to preserve its file attributes
            if shouldKeepParent { subPaths.append("") }
            var totalUnitCount = Int64(0)
            if let progress = progress {
                totalUnitCount = subPaths.reduce(Int64(0), {
                    let itemURL = sourceURL.appendingPathComponent($1)
                    let itemSize = archive.totalUnitCountForAddingItem(at: itemURL)
                    return $0 + itemSize
                })
                progress.totalUnitCount = totalUnitCount
            }

            // If the caller wants to keep the parent directory, we use the lastPathComponent of the source URL
            // as common base for all entries (similar to macOS' Archive Utility.app)
            let directoryPrefix = sourceURL.lastPathComponent
            for entryPath in subPaths {
                let finalEntryPath = shouldKeepParent ? directoryPrefix + "/" + entryPath : entryPath
                let finalBaseURL = shouldKeepParent ? sourceURL.deletingLastPathComponent() : sourceURL
                if let progress = progress {
                    let itemURL = sourceURL.appendingPathComponent(entryPath)
                    let entryProgress = archive.makeProgressForAddingItem(at: itemURL)
                    progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
                    try archive.addEntry(with: finalEntryPath, relativeTo: finalBaseURL,
                                         compressionMethod: compressionMethod, progress: entryProgress,
                                         preservesAppleMetadata: preservesAppleMetadata)
                } else {
                    try archive.addEntry(with: finalEntryPath, relativeTo: finalBaseURL,
                                         compressionMethod: compressionMethod,
                                         preservesAppleMetadata: preservesAppleMetadata)
                }
            }
        } else {
            progress?.totalUnitCount = archive.totalUnitCountForAddingItem(at: sourceURL)
            let baseURL = sourceURL.deletingLastPathComponent()
            try archive.addEntry(with: sourceURL.lastPathComponent, relativeTo: baseURL,
                                 compressionMethod: compressionMethod, progress: progress,
                                 preservesAppleMetadata: preservesAppleMetadata)
        }
    }

    /// Unzips the contents at the specified source URL to the destination URL.
    ///
    /// - Parameters:
    ///   - sourceURL: The file URL pointing to an existing ZIP file.
    ///   - destinationURL: The file URL that identifies the destination directory of the unzip operation.
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - symlinksValidWithin: Any symlink target that resolves outside this URL is rejected for security reasons.
    ///                          Pass `.rootFS` to allow symlinks to point anywhere on the filesystem.
    ///   - maxExtractedBytes: Optional cap on the cumulative number of decompressed bytes produced across
    ///                        all entries (and AppleDouble companions). `ArchiveError.extractedByteLimitExceeded`
    ///                        is thrown if the limit is crossed. Use this to defend against zip bombs when
    ///                        extracting untrusted archives. Partial output on disk is not cleaned up on
    ///                        throw — the caller is responsible for that. Default is `nil` (no limit).
    ///   - progress: A progress object that can be used to track or cancel the unzip operation.
    ///   - pathEncoding: Encoding for entry paths. Overrides the encoding specified in the archive.
    ///   - preservesAppleMetadata: When `true`, `__MACOSX/.../._<name>` AppleDouble companion entries
    ///                             are not written to disk. On Darwin, their extended attributes and
    ///                             resource forks are applied to the corresponding real files instead.
    ///                             When `false`, those entries are extracted verbatim as regular files.
    ///                             Default is `true`.
    /// - Throws: Throws an error if the source item does not exist or the destination URL is not writable.
    public func unzipItem(at sourceURL: URL, to destinationURL: URL,
                          skipCRC32: Bool = false, symlinksValidWithin: URL? = nil,
                          maxExtractedBytes: Int64? = nil,
                          progress: Progress? = nil, pathEncoding: String.Encoding? = nil,
                          preservesAppleMetadata: Bool = true) throws {
        guard self.itemExists(at: sourceURL) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }
        let archive = try Archive(url: sourceURL, accessMode: .read, pathEncoding: pathEncoding)
        try self.unzipItem(archive, to: destinationURL,
                           skipCRC32: skipCRC32, symlinksValidWithin: symlinksValidWithin,
                           maxExtractedBytes: maxExtractedBytes,
                           progress: progress, pathEncoding: pathEncoding,
                           preservesAppleMetadata: preservesAppleMetadata)
    }

    /// Unzips the contents of an already-opened `Archive` to the destination URL.
    ///
    /// Equivalent to `unzipItem(at:to:...)` but accepts an existing `Archive` instead of
    /// constructing one from a source URL. Useful when the archive is already in memory
    /// (e.g. opened from `Data`) or has been opened for other purposes.
    ///
    /// - Parameters:
    ///   - archive: An open `Archive` to extract from.
    ///   - destinationURL: The file URL that identifies the destination directory of the unzip operation.
    ///   - skipCRC32: Optional flag to skip calculation of the CRC32 checksum to improve performance.
    ///   - symlinksValidWithin: Any symlink target that resolves outside this URL is rejected for security reasons.
    ///                          Pass `.rootFS` to allow symlinks to point anywhere on the filesystem.
    ///   - maxExtractedBytes: Optional cap on the cumulative number of decompressed bytes produced across
    ///                        all entries (and AppleDouble companions). `ArchiveError.extractedByteLimitExceeded`
    ///                        is thrown if the limit is crossed. Use this to defend against zip bombs when
    ///                        extracting untrusted archives. Partial output on disk is not cleaned up on
    ///                        throw — the caller is responsible for that. Default is `nil` (no limit).
    ///   - progress: A progress object that can be used to track or cancel the unzip operation.
    ///   - pathEncoding: Encoding for entry paths. Overrides the encoding specified in the archive.
    ///   - preservesAppleMetadata: When `true`, `__MACOSX/.../._<name>` AppleDouble companion entries
    ///                             are not written to disk. On Darwin, their extended attributes and
    ///                             resource forks are applied to the corresponding real files instead.
    ///                             When `false`, those entries are extracted verbatim as regular files.
    ///                             Default is `true`.
    /// - Throws: Throws an error if the destination URL is not writable.
    public func unzipItem(_ archive: Archive, to destinationURL: URL,
                          skipCRC32: Bool = false, symlinksValidWithin: URL? = nil,
                          maxExtractedBytes: Int64? = nil,
                          progress: Progress? = nil, pathEncoding: String.Encoding? = nil,
                          preservesAppleMetadata: Bool = true) throws {
        var totalUnitCount = Int64(0)
        let symlinksValidWithin = symlinksValidWithin ?? destinationURL
        if let progress = progress {
            totalUnitCount = archive.reduce(0, { $0 + archive.totalUnitCountForReading($1) })
            progress.totalUnitCount = totalUnitCount
        }

        // Single budget shared across every per-entry extract so the cap is cumulative, not per-entry.
        let budget = maxExtractedBytes.map { Archive.ByteBudget(limit: $0) }

        // Companion AppleDouble entries may appear in any order relative to their paired real
        // entries. We buffer the parsed payloads and apply them after the main extraction pass.
        var pendingAppleDouble: [String: AppleDoublePayload] = [:]

        // Symlink destinations are checked once all entries are extracted, since a destination may not exist yet
        // and later entries can change where it leads. Entries are never written through symlinks, so a link can't
        // redirect anything in the meantime. Links that lead outside are removed, also when extraction fails.
        var symlinkURLs = [URL]()
        var hasCheckedSymlinks = false
        defer {
            if !hasCheckedSymlinks { _ = self.removeSymlinks(at: symlinkURLs, leadingOutside: symlinksValidWithin) }
        }

        for entry in archive {
            let path = pathEncoding == nil ? entry.path : entry.path(using: pathEncoding!)
            if preservesAppleMetadata {
                // Skip the `__MACOSX/` directory marker itself.
                if path == FileManager.macOSXDirectoryName || path == FileManager.macOSXDirectoryName + "/" {
                    if let progress = progress {
                        progress.completedUnitCount += archive.totalUnitCountForReading(entry)
                    }
                    continue
                }
                if let pairedPath = FileManager.realEntryPath(fromAppleDoubleCompanionPath: path) {
                    var buffer = Data()
                    let rawConsumer: Consumer = { buffer.append($0) }
                    let consumer = budget?.wrap(rawConsumer) ?? rawConsumer
                    if let progress = progress {
                        let entryProgress = archive.makeProgressForReading(entry)
                        progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
                        _ = try archive.extract(entry, skipCRC32: skipCRC32,
                                                progress: entryProgress, consumer: consumer)
                    } else {
                        _ = try archive.extract(entry, skipCRC32: skipCRC32, consumer: consumer)
                    }
                    if let payload = AppleDoublePayload.decode(buffer) {
                        pendingAppleDouble[pairedPath] = payload
                    }
                    continue
                }
            }
            guard let entryURL = self.extractionURL(forEntryPath: path, in: destinationURL) else {
                throw CocoaError(.fileReadInvalidFileName,
                                 userInfo: [NSFilePathErrorKey: destinationURL.appendingPathComponent(path).path])
            }
            let crc32: CRC32
            // unzipItem batches companion handling (see below), so we opt each per-entry extract
            // out of the per-call archive lookup. Symlink destinations are checked after the loop too.
            if let progress = progress {
                let entryProgress = archive.makeProgressForReading(entry)
                progress.addChild(entryProgress, withPendingUnitCount: entryProgress.totalUnitCount)
                crc32 = try archive.extract(entry, to: entryURL,
                                            skipCRC32: skipCRC32,
                                            checksSymlinkDestination: false,
                                            budget: budget,
                                            progress: entryProgress,
                                            preservesAppleMetadata: false)
            } else {
                crc32 = try archive.extract(entry, to: entryURL,
                                            skipCRC32: skipCRC32,
                                            checksSymlinkDestination: false,
                                            budget: budget,
                                            preservesAppleMetadata: false)
            }
            if entry.type == .symlink { symlinkURLs.append(entryURL) }

            func verifyChecksumIfNecessary() throws {
                if skipCRC32 == false, crc32 != entry.checksum {
                    throw Archive.ArchiveError.invalidCRC32
                }
            }
            try verifyChecksumIfNecessary()
        }

        hasCheckedSymlinks = true
        guard self.removeSymlinks(at: symlinkURLs, leadingOutside: symlinksValidWithin) else {
            throw Archive.ArchiveError.uncontainedSymlink
        }

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        if preservesAppleMetadata {
            for (path, payload) in pendingAppleDouble {
                // Companion paths get the same check as regular entries, except that they may describe a symlink
                // itself: the metadata is applied without following it.
                guard let targetURL = self.extractionURL(forEntryPath: path, in: destinationURL,
                                                         allowingSymlinkAtEnd: true),
                      self.itemExists(at: targetURL) else { continue }
                FileManager.applyAppleDoublePayload(payload, to: targetURL)
            }
        }
#else
        _ = pendingAppleDouble
#endif
    }


    // MARK: - Helpers

    /// Returns the URL an archive entry at `path` is written to, or `nil` if the entry would land outside
    /// `destinationURL` or be written through a symlink. Well-formed archives never place entries beneath a
    /// symlink, so this rejects any symlink in the entry's path, including ones extracted from the same archive.
    ///
    /// `.` and `..` are applied to `path` by name, and the entry is written to the result, so a symlink that only
    /// appears in the original path (e.g. `link` in `link/../file`) is never traversed.
    func extractionURL(forEntryPath path: String, in destinationURL: URL, allowingSymlinkAtEnd: Bool = false) -> URL? {
        var components = [Substring]()
        for component in path.split(separator: "/") where component != "." {
            if component == ".." {
                guard components.popLast() != nil else { return nil }
            } else {
                // The file system would only see the part before a NUL.
                guard !component.contains("\0") else { return nil }
                components.append(component)
            }
        }
        var url = destinationURL
        var checksExistingItems = true
        for (index, component) in components.enumerated() {
            url.appendPathComponent(String(component))
            guard checksExistingItems else { continue }
            var fileStat = stat()
            guard lstat(url.path, &fileStat) == 0 else {
                // Nothing below a missing item can exist either.
                checksExistingItems = false
                continue
            }
            let isLastComponent = index == components.count - 1
            if fileStat.st_mode & S_IFMT == S_IFLNK, !(allowingSymlinkAtEnd && isLastComponent) { return nil }
        }
        return url
    }

    /// Removes each symlink in `linkURLs` whose destination leads outside `directoryURL`.
    /// - Returns: Whether all of them led inside.
    func removeSymlinks(at linkURLs: [URL], leadingOutside directoryURL: URL) -> Bool {
        var allContained = true
        for linkURL in linkURLs {
            if let destinationPath = try? self.destinationOfSymbolicLink(atPath: linkURL.path),
               URL.isSymlinkDestination(destinationPath, ofLinkAt: linkURL, containedIn: directoryURL) { continue }
            allContained = false
            _ = try? self.removeItem(at: linkURL)
        }
        return allContained
    }

    func itemExists(at url: URL) -> Bool {
        // Use `URL.checkResourceIsReachable()` instead of `FileManager.fileExists()` here
        // because we don't want implicit symlink resolution.
        // As per documentation, `FileManager.fileExists()` traverses symlinks and therefore a broken symlink
        // would throw a `.fileReadNoSuchFile` false positive error.
        // For ZIP files it may be intended to archive "broken" symlinks because they might be
        // resolvable again when extracting the archive to a different destination.
        return (try? url.checkResourceIsReachable()) == true
    }

    func createParentDirectoryStructure(for url: URL) throws {
        let parentDirectoryURL = url.deletingLastPathComponent()
        try self.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    func transferAttributes(from entry: Entry, toItemAtURL url: URL) throws {
        let attributes = FileManager.attributes(from: entry)
        switch entry.type {
        case .directory, .file:
            try self.setAttributes(attributes, ofItemAtURL: url)
        case .symlink:
            try self.setAttributes(attributes, ofItemAtURL: url, traverseLink: false)
        }
    }

    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtURL url: URL, traverseLink: Bool = true) throws {
        // `FileManager.setAttributes` traverses symlinks and applies the attributes to
        // the symlink destination. Since we want to be able to create symlinks where
        // the destination isn't available (yet), we want to directly apply entry attributes
        // to the symlink (vs. the destination file).
        guard traverseLink == false else {
            try self.setAttributes(attributes, ofItemAtPath: url.path)
            return
        }

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        guard let posixPermissions = attributes[.posixPermissions] as? NSNumber else {
            throw Entry.EntryError.missingPermissionsAttributeError
        }

        try self.setSymlinkPermissions(posixPermissions, ofItemAtURL: url)

        guard let modificationDate = attributes[.modificationDate] as? Date else {
            throw Entry.EntryError.missingModificationDateAttributeError
        }

        try self.setSymlinkModificationDate(modificationDate, ofItemAtURL: url)
#else
        // Since non-Darwin POSIX platforms ignore permissions on symlinks and swift-corelibs-foundation
        // currently doesn't support setting the modification date, this codepath is currently a no-op
        // on these platforms.
        return
#endif
    }

    func setSymlinkPermissions(_ posixPermissions: NSNumber, ofItemAtURL url: URL) throws {
        let fileSystemRepresentation = self.fileSystemRepresentation(withPath: url.path)
        let modeT = posixPermissions.uint16Value
        guard lchmod(fileSystemRepresentation, mode_t(modeT)) == 0 else {
            throw POSIXError(errno, path: url.path)
        }
    }

    func setSymlinkModificationDate(_ modificationDate: Date, ofItemAtURL url: URL) throws {
        let fileSystemRepresentation = self.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        guard lstat(fileSystemRepresentation, &fileStat) == 0 else {
            throw POSIXError(errno, path: url.path)
        }

        let accessDate = fileStat.lastAccessDate
        let array = [
            timeval(timeIntervalSince1970: accessDate.timeIntervalSince1970),
            timeval(timeIntervalSince1970: modificationDate.timeIntervalSince1970)
        ]
        try array.withUnsafeBufferPointer {
            guard lutimes(fileSystemRepresentation, $0.baseAddress) == 0 else {
                throw POSIXError(errno, path: url.path)
            }
        }
    }

    class func attributes(from entry: Entry) -> [FileAttributeKey: Any] {
        let centralDirectoryStructure = entry.centralDirectoryStructure
        let entryType = entry.type
        let fileTime = centralDirectoryStructure.lastModFileTime
        let fileDate = centralDirectoryStructure.lastModFileDate
        let defaultPermissions = entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
        var attributes = [.posixPermissions: defaultPermissions] as [FileAttributeKey: Any]
        attributes[.modificationDate] = Date(dateTime: (fileDate, fileTime))
        let versionMadeBy = centralDirectoryStructure.versionMadeBy
        guard let osType = Entry.OSType(rawValue: UInt(versionMadeBy >> 8)) else { return attributes }

        let externalFileAttributes = centralDirectoryStructure.externalFileAttributes
        let permissions = self.permissions(for: externalFileAttributes, osType: osType, entryType: entryType)
        attributes[.posixPermissions] = NSNumber(value: permissions)
        return attributes
    }

    class func permissions(for externalFileAttributes: UInt32, osType: Entry.OSType,
                           entryType: Entry.EntryType) -> UInt16 {
        switch osType {
        case .unix, .osx:
            let permissions = mode_t(externalFileAttributes >> 16) & (~S_IFMT)
            let defaultPermissions = entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
            return permissions == 0 ? defaultPermissions : UInt16(permissions)
        default:
            return entryType == .directory ? defaultDirectoryPermissions : defaultFilePermissions
        }
    }

    class func externalFileAttributesForEntry(of type: Entry.EntryType, permissions: UInt16) -> UInt32 {
        var typeInt: UInt16
        switch type {
        case .file:
            typeInt = UInt16(S_IFREG)
        case .directory:
            typeInt = UInt16(S_IFDIR)
        case .symlink:
            typeInt = UInt16(S_IFLNK)
        }
        var externalFileAttributes = UInt32(typeInt|UInt16(permissions))
        externalFileAttributes = (externalFileAttributes << 16)
        return externalFileAttributes
    }

    class func permissionsForItem(at URL: URL) throws -> UInt16 {
        let fileManager = FileManager()
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: URL.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
        let permissions = fileStat.st_mode
        return UInt16(permissions)
    }

    class func fileModificationDateTimeForItem(at url: URL) throws -> Date {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        let modTimeSpec = fileStat.st_mtimespec
#else
        let modTimeSpec = fileStat.st_mtim
#endif

        let timeStamp = TimeInterval(modTimeSpec.tv_sec) + TimeInterval(modTimeSpec.tv_nsec)/1000000000.0
        let modDate = Date(timeIntervalSince1970: timeStamp)
        return modDate
    }

    class func fileSizeForItem(at url: URL) throws -> Int64 {
        let fileManager = FileManager()
        guard fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }

        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var stats = stat()
        lstat(entryFileSystemRepresentation, &stats)
        guard stats.st_size >= 0 else { throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path]) }

        // `st_size` is a signed int value
        return Int64(stats.st_size)
    }

    class func typeForItem(at url: URL) throws -> Entry.EntryType {
        let fileManager = FileManager()
        guard url.isFileURL, fileManager.itemExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let entryFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: url.path)
        var fileStat = stat()
        lstat(entryFileSystemRepresentation, &fileStat)
        return Entry.EntryType(mode: mode_t(fileStat.st_mode))
    }
}

extension POSIXError {

    init(_ code: Int32, path: String) {
        let errorCode = POSIXError.Code(rawValue: code) ?? .EPERM
        self = .init(errorCode, userInfo: [NSFilePathErrorKey: path])
    }
}

extension CocoaError {

#if swift(>=4.2)
#else

#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
#else

    // The swift-corelibs-foundation version of NSError.swift was missing a convenience method to create
    // error objects from error codes. (https://github.com/apple/swift-corelibs-foundation/pull/1420)
    // We have to provide an implementation for non-Darwin platforms using Swift versions < 4.2.

    public static func error(_ code: CocoaError.Code, userInfo: [AnyHashable: Any]? = nil, url: URL? = nil) -> Error {
        var info: [String: Any] = userInfo as? [String: Any] ?? [:]
        if let url = url {
            info[NSURLErrorKey] = url
        }
        return NSError(domain: NSCocoaErrorDomain, code: code.rawValue, userInfo: info)
    }

#endif
#endif
}

public extension URL {

    /// Returns whether the receiver is located inside `parentDirectoryURL` on the file system.
    ///
    /// The file system resolves the part of the receiver's path that exists, following symlinks and applying `..`
    /// to the directory actually reached. The rest doesn't exist yet, so the receiver only counts as contained if
    /// that rest can't lead anywhere else once created: it must not start with a symlink or contain `..`.
    /// A path that can't be resolved (e.g. due to a symlink loop) is not contained.
    func isContained(in parentDirectoryURL: URL) -> Bool {
        let startPath = self.path.hasPrefix("/") ? "/" : "."
        return URL.isPath(self.path, resolvedFrom: startPath, containedIn: parentDirectoryURL)
    }
}
