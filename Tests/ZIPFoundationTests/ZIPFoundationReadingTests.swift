//
//  ZIPFoundationReadingTests.swift
//  ZIPFoundation
//
//  Copyright © 2017-2026 Thomas Zoechling, https://www.peakstep.com and the ZIP Foundation project authors.
//  Released under the MIT License.
//
//  See https://github.com/weichsel/ZIPFoundation/blob/master/LICENSE for license information.
//

import XCTest
@testable import ZIPFoundation

extension ZIPFoundationTests {

    func testExtractUncompressedFolderEntries() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            do {
                // Test extracting to memory
                var checksum = try archive.extract(entry, bufferSize: 32, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
                // Test extracting to file
                var fileURL = self.createDirectory(for: #function)
                fileURL.appendPathComponent(entry.path)
                checksum = try archive.extract(entry, to: fileURL)
                XCTAssert(entry.checksum == checksum)
                let fileManager = FileManager()
                XCTAssertTrue(fileManager.itemExists(at: fileURL))
                if entry.type == .file {
                    let fileData = try Data(contentsOf: fileURL)
                    let checksum = fileData.crc32(checksum: 0)
                    XCTAssert(checksum == entry.checksum)
                }
            } catch {
                XCTFail("Failed to unzip uncompressed folder entries")
            }
        }
    }

    func testExtractCompressedFolderEntries() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            do {
                // Test extracting to memory
                var checksum = try archive.extract(entry, bufferSize: 128, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
                // Test extracting to file
                var fileURL = self.createDirectory(for: #function)
                fileURL.appendPathComponent(entry.path)
                checksum = try archive.extract(entry, to: fileURL)
                XCTAssert(entry.checksum == checksum)
                let fileManager = FileManager()
                XCTAssertTrue(fileManager.itemExists(at: fileURL))
                if entry.type != .directory {
                    let fileData = try Data(contentsOf: fileURL)
                    let checksum = fileData.crc32(checksum: 0)
                    XCTAssert(checksum == entry.checksum)
                }
            } catch {
                XCTFail("Failed to unzip compressed folder entries")
            }
        }
    }

    func testExtractUncompressedDataDescriptorArchive() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip data descriptor archive")
            }
        }
    }

    func testExtractCompressedDataDescriptorArchive() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip data descriptor archive")
            }
        }
    }

    func testExtractPreferredEncoding() {
        let encoding = String.Encoding.utf8
        let archive = self.archive(for: #function, mode: .read, preferredEncoding: encoding)
        XCTAssertTrue(archive.checkIntegrity())
        let imageEntry = archive["data/pic👨‍👩‍👧‍👦🎂.jpg"]
        XCTAssertNotNil(imageEntry)
        let textEntry = archive["data/Benoît.txt"]
        XCTAssertNotNil(textEntry)
    }

    func testExtractMSDOSArchive() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            do {
                let checksum = try archive.extract(entry, consumer: { _ in })
                XCTAssert(entry.checksum == checksum)
            } catch {
                XCTFail("Failed to unzip MSDOS archive")
            }
        }
    }

    func testExtractErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        XCTAssertNotNil(archive)
        guard let fileEntry = archive["testZipItem.png"] else {
            XCTFail("Failed to obtain test asset from archive.")
            return
        }
        XCTAssertNotNil(fileEntry)
        XCTAssertCocoaError(try archive.extract(fileEntry, to: archive.url),
                            throwsErrorWithCode: .fileWriteFileExists)
        guard let linkEntry = archive["testZipItemLink"] else {
            XCTFail("Failed to obtain test asset from archive.")
            return
        }

        let longFileName = String(repeating: ProcessInfo.processInfo.globallyUniqueString, count: 100)
        var overlongURL = URL(fileURLWithPath: NSTemporaryDirectory())
        overlongURL.appendPathComponent(longFileName)
        XCTAssertPOSIXError(try archive.extract(fileEntry, to: overlongURL),
                            throwsErrorWithCode: .ENAMETOOLONG)
        XCTAssertNotNil(linkEntry)
        XCTAssertCocoaError(try archive.extract(linkEntry, to: archive.url),
                            throwsErrorWithCode: .fileWriteFileExists)
    }

    func testCorruptFileErrorConditions() throws {
        let archiveURL = self.resourceURL(for: #function, pathExtension: "zip")
        let fileManager = FileManager()
        let destinationFileSystemRepresentation = fileManager.fileSystemRepresentation(withPath: archiveURL.path)
        let destinationFile: FILEPointer = fopen(destinationFileSystemRepresentation, "r+b")

        fseek(destinationFile, 64, SEEK_SET)
        // We have to inject a large enough zeroes block to guarantee that libcompression
        // detects the failure when reading the stream
        _ = try Data.write(chunk: Data(count: 512*1024), to: destinationFile)
        fclose(destinationFile)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard let entry = archive["data.random"] else {
            XCTFail("Failed to read entry.")
            return
        }
        XCTAssertSwiftError(try archive.extract(entry, consumer: { _ in }),
                            throws: Data.CompressionError.corruptedData)
    }

    func testCorruptSymbolicLinkErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        for entry in archive {
            var tempFileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            tempFileURL.appendPathComponent(ProcessInfo.processInfo.globallyUniqueString)
            XCTAssertSwiftError(try archive.extract(entry, to: tempFileURL),
                                throws: Archive.ArchiveError.invalidEntryPath)
        }
    }

    func testInvalidCompressionMethodErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        guard let entry = archive[".DS_Store"] else {
            XCTFail("Missing entry in test archive")
            return
        }

        XCTAssertSwiftError(try archive.extract(entry, consumer: { (_) in }),
                            throws: Archive.ArchiveError.invalidCompressionMethod)
    }

    func testExtractEncryptedArchiveErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        var entriesRead = 0
        for _ in archive {
            entriesRead += 1
        }
        // We currently don't support encryption so we expect failed initialization for entry objects.
        XCTAssert(entriesRead == 0)
    }

    func testExtractInvalidBufferSizeErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        let entry = archive["text.txt"]!
        XCTAssertThrowsError(try archive.extract(entry, to: URL(fileURLWithPath: ""), bufferSize: 0, skipCRC32: true))
        let archive2 = self.archive(for: #function, mode: .read)
        let entry2 = archive2["text.txt"]!
        XCTAssertThrowsError(try archive2.extract(entry2, bufferSize: 0, skipCRC32: true, consumer: { _ in }))
    }

    func testExtractUncompressedEmptyFile() {
        // We had a logic error, where completion handlers for empty entries were not called
        // Ensure that this edge case works
        var didCallCompletion = false
        let archive = self.archive(for: #function, mode: .read)
        guard let entry = archive["empty.txt"] else { XCTFail("Failed to extract entry."); return }

        do {
            _ = try archive.extract(entry) { (data) in
                XCTAssertEqual(data.count, 0)
                didCallCompletion = true
            }
        } catch {
            XCTFail("Unexpected error while trying to extract empty file of uncompressed archive.")
        }
        XCTAssert(didCallCompletion)
    }

    func testExtractUncompressedEntryCancelation() {
        let archive = self.archive(for: #function, mode: .read)
        guard let entry = archive["original"] else { XCTFail("Failed to extract entry."); return }
        let progress = archive.makeProgressForReading(entry)
        do {
            var readCount = 0
            _ = try archive.extract(entry, bufferSize: 1, progress: progress) { (data) in
                readCount += data.count
                if readCount == 4 { progress.cancel() }
            }
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: .ulpOfOne)
        } catch {
            XCTFail("Unexpected error while trying to cancel extraction.")
        }
    }

    func testExtractCompressedEntryCancelation() {
        let archive = self.archive(for: #function, mode: .read)
        guard let entry = archive["random"] else { XCTFail("Failed to extract entry."); return }
        let progress = archive.makeProgressForReading(entry)
        do {
            var readCount = 0
            _ = try archive.extract(entry, bufferSize: 256, progress: progress) { (data) in
                readCount += data.count
                if readCount == 512 { progress.cancel() }
            }
        } catch let error as Archive.ArchiveError {
            XCTAssert(error == Archive.ArchiveError.cancelledOperation)
            XCTAssertEqual(progress.fractionCompleted, 0.5, accuracy: .ulpOfOne)
        } catch {
            XCTFail("Unexpected error while trying to cancel extraction.")
        }
    }

    func testProgressHelpers() {
        let tempPath = NSTemporaryDirectory()
        var nonExistantURL = URL(fileURLWithPath: tempPath)
        nonExistantURL.appendPathComponent("invalid.path")
        let archive = self.archive(for: #function, mode: .update)
        XCTAssert(archive.totalUnitCountForAddingItem(at: nonExistantURL) == -1)
    }

    func testDetectEntryType() {
        let archive = self.archive(for: #function, mode: .read)
        let expectedData: [String: Entry.EntryType] = [
            "META-INF/": .directory,
            "META-INF/container.xml": .file
        ]
        for entry in archive {
            XCTAssertEqual(entry.type, expectedData[entry.path])
        }
    }

    func testCRC32Check() {
        let fileManager = FileManager()
        let archive = self.archive(for: #function, mode: .read)
        let destinationURL = self.createDirectory(for: #function)
        XCTAssertSwiftError(try fileManager.unzipItem(at: archive.url, to: destinationURL),
                            throws: Archive.ArchiveError.invalidCRC32)
    }

    func testSimpleTraversalAttack() {
        let fileManager = FileManager()
        let archive = self.archive(for: #function, mode: .read)
        let destinationURL = self.createDirectory(for: #function)
        XCTAssertCocoaError(try fileManager.unzipItem(at: archive.url, to: destinationURL),
                            throwsErrorWithCode: .fileReadInvalidFileName)
    }

    func testPathDelimiterTraversalAttack() {
        let fileManager = FileManager()
        let archive = self.archive(for: #function, mode: .read)
        let destinationURL = self.createDirectory(for: #function)
        XCTAssertCocoaError(try fileManager.unzipItem(at: archive.url, to: destinationURL),
                            throwsErrorWithCode: .fileReadInvalidFileName)
    }

    func testSymlinkTraversalAttack() throws {
        // `link` points at the destination itself, so on disk `link/..` is the destination's parent,
        // even though `destination/link/../outside` looks like `destination/outside` as a string.
        let fileManager = FileManager()
        let destinationURL = self.createDirectory(for: #function)
        let archiveURL = try self.makeArchive(for: #function, entries: [
            ("link", .symlink, "."),
            ("escape", .symlink, "link/../outside")
        ])
        XCTAssertSwiftError(try fileManager.unzipItem(at: archiveURL, to: destinationURL),
                            throws: Archive.ArchiveError.uncontainedSymlink)
        XCTAssertFalse(fileManager.itemExists(at: destinationURL.appendingPathComponent("escape")))
    }

    func testSymlinkChainTraversalAttack() throws {
        // `dir/up` resolves to the destination, so `dir/up/..` climbs out of it.
        let fileManager = FileManager()
        let destinationURL = self.createDirectory(for: #function)
        let archiveURL = try self.makeArchive(for: #function, entries: [
            ("dir/", .directory, ""),
            ("dir/up", .symlink, ".."),
            ("dir/escape", .symlink, "up/..")
        ])
        XCTAssertSwiftError(try fileManager.unzipItem(at: archiveURL, to: destinationURL),
                            throws: Archive.ArchiveError.uncontainedSymlink)
        XCTAssertFalse(fileManager.itemExists(at: destinationURL.appendingPathComponent("dir/escape")))
    }

    func testSymlinkThroughMissingDirectoryTraversalAttack() throws {
        // While `missing` doesn't exist, `missing/../outside` stays inside the destination. The next entry
        // turns `missing` into a link to `.`, which would move `link` to the destination's parent.
        let fileManager = FileManager()
        let destinationURL = self.createDirectory(for: #function)
        let archiveURL = try self.makeArchive(for: #function, entries: [
            ("link", .symlink, "missing/../outside"),
            ("missing", .symlink, ".")
        ])
        XCTAssertSwiftError(try fileManager.unzipItem(at: archiveURL, to: destinationURL),
                            throws: Archive.ArchiveError.uncontainedSymlink)
        XCTAssertFalse(fileManager.itemExists(at: destinationURL.appendingPathComponent("link")))
    }

    func testEntryThroughSymlinkTraversalAttack() throws {
        // Symlinks may point anywhere with `.rootFS`, but entries must still not be written through them.
        let fileManager = FileManager()
        let outsideURL = self.createDirectory(for: #function + "Outside")
        let entryTypes: [Entry.EntryType] = [.file, .directory, .symlink]
        for type in entryTypes {
            let name = #function + "\(type)"
            let destinationURL = self.createDirectory(for: name)
            let archiveURL = try self.makeArchive(for: name, entries: [
                ("link", .symlink, outsideURL.path),
                (type == .directory ? "link/item/" : "link/item", type, "item")
            ])
            XCTAssertCocoaError(try fileManager.unzipItem(at: archiveURL, to: destinationURL,
                                                          symlinksValidWithin: .rootFS),
                                throwsErrorWithCode: .fileReadInvalidFileName)
            XCTAssertFalse(fileManager.itemExists(at: outsideURL.appendingPathComponent("item")))
        }
    }

    func testEntryThroughContainedSymlinkIsRejected() throws {
        // Well-formed archives never place entries beneath a symlink, even one that stays inside the destination.
        let fileManager = FileManager()
        let destinationURL = self.createDirectory(for: #function)
        let archiveURL = try self.makeArchive(for: #function, entries: [
            ("dir/", .directory, ""),
            ("link", .symlink, "dir"),
            ("link/file.txt", .file, "content")
        ])
        XCTAssertCocoaError(try fileManager.unzipItem(at: archiveURL, to: destinationURL),
                            throwsErrorWithCode: .fileReadInvalidFileName)
        XCTAssertFalse(fileManager.itemExists(at: destinationURL.appendingPathComponent("dir/file.txt")))
    }

    func testUnzipContainedSymlinks() throws {
        let fileManager = FileManager()
        let realDestinationURL = self.createDirectory(for: #function)
        // Symlinks leading to the destination itself are resolved before checking containment.
        var destinationURL = ZIPFoundationTests.tempZipDirectoryURL
        destinationURL.appendPathComponent(self.pathComponent(for: #function) + "Link")
        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: realDestinationURL)
        let archiveURL = try self.makeArchive(for: #function, entries: [
            // Parent directories that don't exist yet are created before the destination is resolved.
            ("dir/nested/up", .symlink, "../file.txt"),
            ("dir/file.txt", .file, "content"),
            ("dir/link", .symlink, "file.txt"),
            // Link destinations may pass through symlinks extracted earlier.
            ("chained", .symlink, "dir/link"),
            ("absolute", .symlink, realDestinationURL.appendingPathComponent("dir/file.txt").path),
            ("dir/sub/", .directory, ""),
            ("dir/sub/../sibling.txt", .file, "sibling")
        ])
        try fileManager.unzipItem(at: archiveURL, to: destinationURL)
        for path in ["dir/nested/up", "dir/link", "chained", "absolute"] {
            let linkURL = realDestinationURL.appendingPathComponent(path)
            XCTAssertEqual(try String(contentsOf: linkURL, encoding: .utf8), "content")
        }
        let siblingURL = realDestinationURL.appendingPathComponent("dir/sibling.txt")
        XCTAssertEqual(try String(contentsOf: siblingURL, encoding: .utf8), "sibling")
    }

    func testIsContainedResolvesSymlinks() throws {
        let fileManager = FileManager()
        let directoryURL = self.createDirectory(for: #function)
        try fileManager.createSymbolicLink(atPath: directoryURL.appendingPathComponent("link").path,
                                           withDestinationPath: ".")
        let directoryLinkURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent(directoryURL.lastPathComponent + "Link")
        try fileManager.createSymbolicLink(at: directoryLinkURL, withDestinationURL: directoryURL)
        let siblingURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent(directoryURL.lastPathComponent + "Sibling/file")

        XCTAssert(directoryURL.appendingPathComponent("missing/../file").isContained(in: directoryURL))
        XCTAssert(directoryLinkURL.appendingPathComponent("file").isContained(in: directoryURL))
        XCTAssert(directoryURL.appendingPathComponent("file").isContained(in: directoryLinkURL))
        XCTAssertFalse(directoryURL.appendingPathComponent("link/../file").isContained(in: directoryURL))
        XCTAssertFalse(directoryURL.appendingPathComponent("//../file").isContained(in: directoryURL))
        XCTAssertFalse(siblingURL.isContained(in: directoryURL))
    }

    func testInvalidSymlinkCompressionMethodErrorConditions() {
        let archive = self.archive(for: #function, mode: .read)
        guard let entry = archive["symlink"] else {
            XCTFail("Missing entry in test archive")
            return
        }

        XCTAssertSwiftError(try archive.extract(entry, consumer: { (_) in }),
                            throws: Archive.ArchiveError.invalidCompressionMethod)
    }
}
