import Foundation
import CryptoKit
import Darwin

struct CASCObject {
    let key: String
    let file: URL
}

/// Builds a small local CASC store from downloaded, encoded BLTE objects.
/// Additional game assets remain the responsibility of the client's streamer.
///
/// Format references: CascLib CascStructs.h, CascIndexFiles.cpp and
/// CascReadFile.cpp. The lookup3 implementation follows Bob Jenkins' public
/// domain lookup3.c (May 2006). See the notice at the end of this file.
enum CASCStorage {
    private static let segmentSize: UInt64 = 0x40000000
    // Native 12.0.7 mapping-table header value, observed in all reference
    // indices. It is not the per-archive (data.###) rollover size above.
    private static let maximumStorageOffset: UInt64 = 0x000000ffc0000000
    private static let spanHeaderSize: UInt64 = 30
    private static let indexFormatMarker = ".firestorm-index-format"
    private static let indexFormatVersion = Data("native-kmt-v2\n".utf8)

    private struct Source {
        let key: [UInt8]
        let file: URL
        let length: UInt64
    }

    private struct Entry {
        let key: [UInt8]
        let offset: UInt64
        let length: UInt32

        var bucket: Int {
            let folded = key.prefix(9).reduce(UInt8(0), ^)
            return Int((folded ^ (folded >> 4)) & 0x0f)
        }

        var encoded: [UInt8] {
            var result = Array(key.prefix(9))
            result += (0..<5).reversed().map { UInt8(truncatingIfNeeded: offset >> ($0 * 8)) }
            result += CASCStorage.littleEndian(length)
            return result
        }
    }

    static func create(in directory: URL, objects: [CASCObject]) throws {
        let files = FileManager.default
        guard directory.isFileURL, !objects.isEmpty else {
            throw LauncherFailure("CASC storage requires a local folder and at least one downloaded object.")
        }
        let destination = directory.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        var wasEmptyDirectory = false
        if let attrs = try? files.attributesOfItem(atPath: destination.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  try files.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw LauncherFailure("CASC storage can only be created in a new or empty data folder.")
            }
            wasEmptyDirectory = true
        }

        var keys = Set<String>()
        var prefixes = Set<Data>()
        var sources: [Source] = []
        var totalLength: UInt64 = 0
        for object in objects {
            let key = try decodeKey(object.key)
            let normalizedKey = object.key.lowercased()
            guard keys.insert(normalizedKey).inserted, prefixes.insert(Data(key.prefix(9))).inserted else {
                throw LauncherFailure("Duplicate or colliding CASC object keys were supplied.")
            }
            guard object.file.isFileURL else { throw LauncherFailure("A downloaded CASC object is not a local file.") }
            let attrs = try files.attributesOfItem(atPath: object.file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber else {
                throw LauncherFailure("A downloaded CASC object is not a regular file.")
            }
            let length = size.uint64Value
            guard length >= 9, length <= UInt64(UInt32.max) - spanHeaderSize,
                  totalLength + length + spanHeaderSize < segmentSize else {
                throw LauncherFailure("The starter objects exceed the supported single CASC archive size.")
            }
            try validateBLTE(object.file, key: key, length: length)
            sources.append(Source(key: key, file: object.file, length: length))
            totalLength += length + spanHeaderSize
        }

        let stage = parent.appendingPathComponent(".casc-storage-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }
        let archiveURL = stage.appendingPathComponent("data.000")
        guard files.createFile(atPath: archiveURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LauncherFailure("Could not create the starter CASC archive.")
        }
        let archive = try FileHandle(forWritingTo: archiveURL)
        defer { try? archive.close() }
        var entries: [Entry] = []
        var offset: UInt64 = 0
        for source in sources {
            let storedLength = UInt32(source.length + spanHeaderSize)
            let header = spanHeader(key: source.key, storedLength: storedLength, offset: offset)
            try archive.write(contentsOf: Data(header))
            let input = try FileHandle(forReadingFrom: source.file)
            do {
                var remaining = source.length
                while remaining > 0 {
                    let requested = Int(min(remaining, 4 * 1024 * 1024))
                    guard let block = try input.read(upToCount: requested), !block.isEmpty else {
                        throw LauncherFailure("A downloaded CASC object changed while storage was being created.")
                    }
                    try archive.write(contentsOf: block)
                    remaining -= UInt64(block.count)
                }
                if let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
                    throw LauncherFailure("A downloaded CASC object changed while storage was being created.")
                }
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
            entries.append(Entry(key: source.key, offset: offset, length: storedLength))
            offset += UInt64(storedLength)
        }
        try archive.synchronize()

        for bucket in 0..<16 {
            let bucketEntries = entries.filter { $0.bucket == bucket }.sorted {
                $0.key.prefix(9).lexicographicallyPrecedes($1.key.prefix(9))
            }
            let index = indexFile(bucket: UInt8(bucket), entries: bucketEntries)
            let name = String(format: "%02x00000001.idx", bucket)
            try Data(index).write(to: stage.appendingPathComponent(name), options: .atomic)
        }
        try indexFormatVersion.write(to: stage.appendingPathComponent(indexFormatMarker), options: .atomic)

        if wasEmptyDirectory {
            // rmdir only succeeds while it remains empty; never recursively
            // remove a destination another process may have populated.
            guard Darwin.rmdir(destination.path) == 0 else {
                throw LauncherFailure("The destination data folder changed during CASC installation.")
            }
        }
        do {
            try files.moveItem(at: stage, to: destination)
        } catch {
            if wasEmptyDirectory, !files.fileExists(atPath: destination.path) {
                try? files.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            throw error
        }
    }

    /// Only recognizes the exact short index layout emitted by launcher 1.1–
    /// 1.1.2. Healthy native indices, later versions, and linked paths are left
    /// alone. Inspection does not modify or initialize any game files.
    static func needsIndexUpgrade(in directory: URL) -> Bool {
        (try? legacyIndices(in: directory)) != nil
    }

    /// Rewrites only our old mapping tables; data.000 and every game archive
    /// remain byte-for-byte unchanged. A recoverable backup includes the old
    /// tables and native runtime state before any publication begins.
    static func rebuildIndices(in directory: URL) throws {
        let files = FileManager.default
        guard !LauncherCore.gameIsRunning() else { throw LauncherFailure("Close World of Warcraft before repairing game data indices.") }
        let directory = directory.standardizedFileURL
        let legacy = try legacyIndices(in: directory)
        let parent = directory.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".firestorm-index-stage-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".firestorm-index-backup-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }
        for bucket in 0..<16 {
            let name = String(format: "%02x00000001.idx", bucket)
            let entries = legacy.entries.filter { $0.bucket == bucket }.sorted {
                $0.key.prefix(9).lexicographicallyPrecedes($1.key.prefix(9))
            }
            try Data(indexFile(bucket: UInt8(bucket), entries: entries)).write(to: stage.appendingPathComponent(name), options: .atomic)
        }
        try indexFormatVersion.write(to: stage.appendingPathComponent(indexFormatMarker), options: .atomic)

        var originals = legacy.files
        let names = try files.contentsOfDirectory(atPath: directory.path)
        for name in names where name == "RepairMarker.psv" || name == "shmem" || name == indexFormatMarker || name.hasPrefix("index.lock.") {
            let file = directory.appendingPathComponent(name)
            guard try files.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
                throw LauncherFailure("The index runtime state contains an unsupported file: \(name).")
            }
            originals[name] = try Data(contentsOf: file)
        }
        guard !LauncherCore.gameIsRunning() else { throw LauncherFailure("Close World of Warcraft before repairing game data indices.") }
        // Re-read only for publication concurrency: a running client or another
        // installer must not have replaced a table after the initial snapshot.
        for (name, bytes) in originals {
            guard try Data(contentsOf: directory.appendingPathComponent(name)) == bytes else {
                throw LauncherFailure("Game data indices changed while repair was being prepared. Close the game and try again.")
            }
        }
        try files.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in originals.keys {
            try files.copyItem(at: directory.appendingPathComponent(name), to: backup.appendingPathComponent(name))
        }
        let description = Data("Firestorm launcher legacy index backup. Archives were not changed.\n".utf8)
        try description.write(to: backup.appendingPathComponent("README.txt"), options: .atomic)
        var removedRuntime = [String]()
        var replaced = [String]()
        do {
            guard !LauncherCore.gameIsRunning() else { throw LauncherFailure("Close World of Warcraft before repairing game data indices.") }
            for bucket in 0..<16 {
                let name = String(format: "%02x00000001.idx", bucket)
                try atomicRename(stage.appendingPathComponent(name), directory.appendingPathComponent(name))
                replaced.append(name)
            }
            try atomicRename(stage.appendingPathComponent(indexFormatMarker), directory.appendingPathComponent(indexFormatMarker))
            replaced.append(indexFormatMarker)
            // The client must recreate mapping state from the repaired tables.
            // Remove stale runtime state only after every new table is present.
            for name in originals.keys.sorted() where !name.hasSuffix(".idx") && name != indexFormatMarker {
                try files.removeItem(at: directory.appendingPathComponent(name))
                removedRuntime.append(name)
            }
        } catch {
            var rollbackFailed = false
            for name in replaced {
                do {
                    if originals[name] != nil {
                        let restored = stage.appendingPathComponent("rollback-\(name)")
                        try files.copyItem(at: backup.appendingPathComponent(name), to: restored)
                        try atomicRename(restored, directory.appendingPathComponent(name))
                    } else { try files.removeItem(at: directory.appendingPathComponent(name)) }
                } catch { rollbackFailed = true }
            }
            for name in removedRuntime {
                do { try files.copyItem(at: backup.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw LauncherFailure("Index repair could not finish its rollback. Original indices are saved in \(backup.path).") }
            throw error
        }
    }

    private static func atomicRename(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw LauncherFailure("Could not replace game data index \(destination.lastPathComponent): \(String(cString: strerror(errno))).")
        }
    }

    private struct LegacyIndices {
        let entries: [Entry]
        let files: [String: Data]
    }

    private static func legacyIndices(in directory: URL) throws -> LegacyIndices {
        let files = FileManager.default
        let directory = directory.standardizedFileURL
        guard directory.isFileURL, directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.path,
              try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw LauncherFailure("Index repair requires an ordinary local data directory.")
        }
        let expectedNames = Set((0..<16).map { String(format: "%02x00000001.idx", $0) })
        let actualNames = Set(try files.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".idx") })
        guard actualNames == expectedNames else { throw LauncherFailure("These are not legacy launcher-generated indices.") }
        let archive = directory.appendingPathComponent("data.000")
        let archiveAttributes = try files.attributesOfItem(atPath: archive.path)
        guard archiveAttributes[.type] as? FileAttributeType == .typeRegular,
              let archiveSize = archiveAttributes[.size] as? NSNumber,
              archiveSize.uint64Value > 0, archiveSize.uint64Value < segmentSize else {
            throw LauncherFailure("The legacy starter archive is missing or unsupported.")
        }
        var entries = [Entry]()
        var snapshot = [String: Data]()
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        }
        func u64(_ data: Data, _ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        for bucket in 0..<16 {
            let name = String(format: "%02x00000001.idx", bucket)
            let url = directory.appendingPathComponent(name)
            let attributes = try files.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let fileSize = attributes[.size] as? NSNumber, fileSize.intValue >= 40, fileSize.intValue < 0x10000 else {
                throw LauncherFailure("These are not legacy launcher-generated indices.")
            }
            let data = try Data(contentsOf: url)
            guard data.count == fileSize.intValue, u32(data, 0) == 16,
                  Array(data[8..<16]) == [7, 0, UInt8(bucket), 0, 4, 5, 9, 30],
                  u64(data, 16) == segmentSize,
                  u32(data, 4) == lookup3(Array(data[8..<24])).high else {
                throw LauncherFailure("These are not legacy launcher-generated indices.")
            }
            let length = Int(u32(data, 32))
            guard length % 18 == 0, length <= data.count - 40 else { throw LauncherFailure("A legacy index table is incomplete.") }
            var high: UInt32 = 0
            var low: UInt32 = 0
            for cursor in stride(from: 40, to: 40 + length, by: 18) {
                let bytes = Array(data[cursor..<(cursor + 18)])
                let hash = lookup3(bytes, primary: high, secondary: low)
                high = hash.high; low = hash.low
                let prefix = Array(bytes.prefix(9))
                let offset = bytes[9..<14].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let spanLength = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[14 + $1]) << ($1 * 8) }
                let entry = Entry(key: prefix + [UInt8](repeating: 0, count: 7), offset: offset, length: spanLength)
                guard entry.bucket == bucket, spanLength > UInt32(spanHeaderSize), offset < archiveSize.uint64Value,
                      UInt64(spanLength) <= archiveSize.uint64Value - offset else {
                    throw LauncherFailure("A legacy index entry is invalid.")
                }
                entries.append(entry)
            }
            guard u32(data, 36) == high else { throw LauncherFailure("A legacy index checksum is invalid.") }
            snapshot[name] = data
        }
        return LegacyIndices(entries: entries, files: snapshot)
    }

    private static func decodeKey(_ text: String) throws -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count == 32 else { throw LauncherFailure("An encoded CASC object key must contain 32 hexadecimal characters.") }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        var result: [UInt8] = []
        for cursor in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[cursor]), let low = nibble(bytes[cursor + 1]) else {
                throw LauncherFailure("A CASC object key contains a non-hexadecimal character.")
            }
            result.append((high << 4) | low)
        }
        return result
    }

    private static func validateBLTE(_ file: URL, key: [UInt8], length: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8,
              prefix.prefix(4) == Data("BLTE".utf8) else {
            throw LauncherFailure("A starter CASC object does not contain a BLTE header.")
        }
        let p = Array(prefix)
        let headerLength = (UInt32(p[4]) << 24) | (UInt32(p[5]) << 16) | (UInt32(p[6]) << 8) | UInt32(p[7])
        guard headerLength == 0 || (headerLength >= 12 && UInt64(headerLength) <= length) else {
            throw LauncherFailure("A starter CASC object has an invalid BLTE header length.")
        }
        // Chunked EKeys cover only the complete BLTE header; a single-frame
        // object with a zero header length hashes the entire encoded object.
        var hasher = Insecure.MD5()
        hasher.update(data: prefix)
        var remaining = (headerLength == 0 ? length : UInt64(headerLength)) - 8
        while remaining > 0 {
            guard let block = try handle.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))), !block.isEmpty else {
                throw LauncherFailure("A starter CASC object is incomplete.")
            }
            hasher.update(data: block)
            remaining -= UInt64(block.count)
        }
        guard Array(hasher.finalize()) == key else {
            throw LauncherFailure("The encoded key of a starter CASC object does not match its BLTE header.")
        }
    }

    private static func spanHeader(key: [UInt8], storedLength: UInt32, offset: UInt64) -> [UInt8] {
        var header = Array(key.reversed())
        header += littleEndian(storedLength)
        header += [0, 0]
        header += littleEndian(lookup3(header, primary: 0x3D6BE971).high)
        let table: [UInt32] = [
            0x049396B8, 0x72A82A9B, 0xEE626CCA, 0x9917754F,
            0x15DE40B1, 0xF5A8A9B6, 0x421EAC7E, 0xA9D55C9A,
            0x317FD40C, 0x04FAF80D, 0x3D6BE971, 0x52933CFD,
            0x27F64B7D, 0xC6F5C11B, 0xD5757E3A, 0x6C388745
        ]
        let blteOffset = UInt32(truncatingIfNeeded: offset + spanHeaderSize)
        let encodedOffset = littleEndian(table[Int(blteOffset & 15)] ^ blteOffset)
        var folded = [UInt8](repeating: 0, count: 4)
        for index in 0..<header.count { folded[index & 3] ^= header[index] }
        let start = header.count
        for index in 0..<4 {
            let lane = (start + index) & 3
            header.append(folded[lane] ^ encodedOffset[lane])
        }
        return header
    }

    private static func indexFile(bucket: UInt8, entries: [Entry]) -> [UInt8] {
        var payload: [UInt8] = [7, 0, bucket, 0, 4, 5, 9, 30]
        payload += (0..<8).map { UInt8(truncatingIfNeeded: maximumStorageOffset >> ($0 * 8)) }
        var output = littleEndian(UInt32(payload.count))
        output += littleEndian(lookup3(payload).high)
        output += payload
        output += [UInt8](repeating: 0, count: 8)

        var body: [UInt8] = []
        var high: UInt32 = 0
        var low: UInt32 = 0
        for entry in entries {
            let bytes = entry.encoded
            let hash = lookup3(bytes, primary: high, secondary: low)
            high = hash.high
            low = hash.low
            body += bytes
        }
        output += littleEndian(UInt32(body.count))
        output += littleEndian(high)
        output += body
        // Native mapping tables consist of a guarded sorted base followed by
        // a page-aligned KMT update region, including for an empty bucket.
        // All 32 working reference indices have >=0x8000 zero update bytes
        // after this alignment and a 64KiB-aligned EOF. A total file length of
        // only 0x8000 left 0x7000 update bytes and caused "Truncated KMT update
        // section" before the first mapping table could bind.
        let updateStart = (output.count + 0x0fff) & ~0x0fff
        let fileLength = (updateStart + 0x8000 + 0xffff) & ~0xffff
        output += [UInt8](repeating: 0, count: fileLength - output.count)
        return output
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func rotate(_ value: UInt32, _ bits: Int) -> UInt32 {
        (value << bits) | (value >> (32 - bits))
    }

    private static func lookup3(_ bytes: [UInt8], primary: UInt32 = 0, secondary: UInt32 = 0) -> (high: UInt32, low: UInt32) {
        let initial = UInt32(0xDEADBEEF) &+ UInt32(truncatingIfNeeded: bytes.count) &+ primary
        var a = initial
        var b = initial
        var c = initial &+ secondary
        var cursor = 0
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        while bytes.count - cursor > 12 {
            a = a &+ word(cursor)
            b = b &+ word(cursor + 4)
            c = c &+ word(cursor + 8)
            a = a &- c; a ^= rotate(c, 4); c = c &+ b
            b = b &- a; b ^= rotate(a, 6); a = a &+ c
            c = c &- b; c ^= rotate(b, 8); b = b &+ a
            a = a &- c; a ^= rotate(c, 16); c = c &+ b
            b = b &- a; b ^= rotate(a, 19); a = a &+ c
            c = c &- b; c ^= rotate(b, 4); b = b &+ a
            cursor += 12
        }
        let remaining = bytes.count - cursor
        guard remaining > 0 else { return (c, b) }
        for index in 0..<remaining {
            let value = UInt32(bytes[cursor + index]) << ((index & 3) * 8)
            if index < 4 { a = a &+ value }
            else if index < 8 { b = b &+ value }
            else { c = c &+ value }
        }
        c ^= b; c = c &- rotate(b, 14)
        a ^= c; a = a &- rotate(c, 11)
        b ^= a; b = b &- rotate(a, 25)
        c ^= b; c = c &- rotate(b, 16)
        a ^= c; a = a &- rotate(c, 4)
        b ^= a; b = b &- rotate(a, 14)
        c ^= b; c = c &- rotate(b, 24)
        return (c, b)
    }
}

/*
Format excerpts and header-checksum constants adapted from CascLib.
The MIT License (MIT)
Copyright (c) 2014 Ladislav Zezula

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
