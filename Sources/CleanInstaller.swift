import Foundation
import CryptoKit
import Darwin

struct InstallProgress {
    let message: String
    let completedBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

final class InstallCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var active: URLSessionTask?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; let task = active; lock.unlock(); task?.cancel() }
    func attach(_ task: URLSessionTask?) { lock.lock(); active = task; let stop = cancelled; lock.unlock(); if stop { task?.cancel() } }
    func check() throws { if isCancelled { throw LauncherFailure("Installation paused. Click Install to resume the download.") } }
}

/// Downloads the pinned Firestorm metadata required by a streaming installation.
/// The macOS game streams the remaining world assets directly from the same CDN.
// Instances hold only the immutable core/resource location; installation state
// is local to install(), and file locks serialize writes to each destination.
final class CleanInstaller: @unchecked Sendable {
    static let build = "c11d132e14cdbb1ae632620aa3e61aef"
    static let cdn = "4af4fdf8ceef1d69a3df3c5be6712a60"
    static let keyring = "3ca57fe7319a297346440e4d2a03a0cd"
    static let server = "http://57.129.6.7:105"
    static var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Firestorm Midnight", isDirectory: true)
    }
    static func stagingDirectory(for destination: URL) -> URL {
        let destination = destination.standardizedFileURL
        let identity = SHA256.hash(data: Data(destination.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return destination.deletingLastPathComponent().appendingPathComponent(".firestorm-download-\(identity)", isDirectory: true)
    }

    private struct RemoteObject {
        let key: String
        let size: Int64
        let kind: String
        let title: String
        var relative: String { "tpr/wow/\(kind)/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)" }
    }
    private struct Checkpoint: Codable, Equatable {
        let destination: String
        let version: String
        let locale: String
    }
    private static let objects: [RemoteObject] = [
        .init(key: build, size: 87_634, kind: "config", title: "build configuration"),
        .init(key: cdn, size: 56_208, kind: "config", title: "CDN configuration"),
        .init(key: keyring, size: 56, kind: "config", title: "content keys"),
        .init(key: "8dbc6fd0f675ed19ad9e140fe2cf6728", size: 184_694_766, kind: "data", title: "content index"),
        .init(key: "8ee05b52db9f4fa8f1ea0b8ed4bfa913", size: 49_765_710, kind: "data", title: "world file index"),
        .init(key: "05baf62179a725f8df952a6bcde55246", size: 34_947, kind: "data", title: "client file index"),
        .init(key: "a7f469b9f1739b602fa2ee2884d20a03", size: 22_368, kind: "data", title: "installation metadata"),
        .init(key: "7d21378c518036e39d06a214b2110539", size: 62_311_242, kind: "data", title: "streaming manifest")
        // SIZE is auxiliary metadata, not a required storage-open payload. Keep
        // its reference in the unmodified build config for the game streamer.
        // Requiring it here blocked installation after all starter files arrived.
    ]

    private let core: LauncherCore
    init(core: LauncherCore = LauncherCore()) { self.core = core }

    func install(to destination: URL, locale: String, cancellation: InstallCancellation,
                 progress: @escaping (InstallProgress) -> Void) throws -> GameInstallation {
        let fm = FileManager.default
        let destination = destination.standardizedFileURL
        guard destination.isFileURL, destination.path != "/", !fm.fileExists(atPath: destination.path) else {
            throw LauncherFailure("The installation folder already exists. Select it as an existing client or choose a new folder.")
        }
        guard ["ruRU", "enUS", "enGB", "deDE", "frFR", "esES"].contains(locale) else { throw LauncherFailure("Unsupported game language.") }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalParent == parent else { throw LauncherFailure("Choose an installation folder without symbolic links.") }
        let stage = Self.stagingDirectory(for: destination)
        try LauncherCore.ensureMutablePath(stage, root: parent)
        // A paused installation deliberately keeps this directory and its parts.
        // Creating with intermediate directories permits reusing that directory.
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(stage.appendingPathComponent("install.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LauncherFailure("Cannot lock the installation folder.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw LauncherFailure("Another launcher is already downloading this installation.") }
        defer { _ = flock(descriptor, LOCK_UN) }
        // The checkpoint binds the reused directory to this destination and locale.
        let checkpointURL = stage.appendingPathComponent("checkpoint.json")
        let checkpoint = Checkpoint(destination: destination.path, version: GameInstallation.supportedVersion, locale: locale)
        if fm.fileExists(atPath: checkpointURL.path) {
            guard let saved = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL)), saved == checkpoint else {
                throw LauncherFailure("This partial installation uses a different folder or language. Choose its original language to resume.")
            }
        } else {
            try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
        }
        try cancellation.check()
        let capacity = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard (capacity.volumeAvailableCapacityForImportantUsage ?? Int64.max) >= 3_000_000_000 else {
            throw LauncherFailure("At least 3 GB of free space is needed for the starter installation. The game will need more space as world assets stream in.")
        }
        let downloads = stage.appendingPathComponent("downloads", isDirectory: true)
        try LauncherCore.ensureMutablePath(downloads, root: stage)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let total = Self.objects.reduce(Int64(0)) { $0 + $1.size }
        var finished: Int64 = 0
        let start = Date()
        let initialBytes = Self.objects.reduce(Int64(0)) { amount, object in
            if fm.fileExists(atPath:downloads.appendingPathComponent(object.key).path) { return amount + object.size }
            let part = downloads.appendingPathComponent(object.key + ".part")
            return amount + min(object.size, ((try? fm.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
        for object in Self.objects {
            try cancellation.check()
            let file = downloads.appendingPathComponent(object.key)
            try LauncherCore.ensureMutablePath(file, root: stage)
            if fm.fileExists(atPath: file.path), (try? Self.validate(file, object: object)) == nil { try fm.removeItem(at: file) }
            if !fm.fileExists(atPath: file.path) {
                let base = finished
                let url = URL(string: Self.server + "/" + object.relative)!
                var lastError: Error?
                for attempt in 0..<3 {
                    try cancellation.check()
                    do {
                        let transfer = StreamDownload(url: url, destination: file, expected: object.size, cancellation: cancellation, objectName: object.title) { received in
                            let all = base + received
                            let elapsed = max(0.1, Date().timeIntervalSince(start))
                            let rate = max(0, Double(all - initialBytes) / elapsed)
                            progress(.init(message: "Downloading \(object.title)…", completedBytes: all, totalBytes: total, bytesPerSecond: rate))
                        }
                        try transfer.perform()
                        progress(.init(message: "Checking \(object.title)…", completedBytes: base + object.size, totalBytes: total, bytesPerSecond: 0))
                        try Self.validate(file, object: object)
                        lastError = nil
                        break
                    } catch {
                        lastError = error
                        if cancellation.isCancelled { throw error }
                        if fm.fileExists(atPath: file.path) { try? fm.removeItem(at: file) }
                        if attempt < 2 { progress(.init(message: "Connection interrupted. Retrying \(object.title)…", completedBytes: base, totalBytes: total, bytesPerSecond: 0)) }
                    }
                }
                if let lastError { throw lastError }
            }
            finished += object.size
            progress(.init(message: "Downloaded \(object.title).", completedBytes: finished, totalBytes: total, bytesPerSecond: 0))
        }
        try cancellation.check()
        let install = stage.appendingPathComponent("client", isDirectory: true)
        try LauncherCore.ensureMutablePath(install, root: stage)
        // This is only our uncommitted staging tree; checked downloads stay intact.
        if fm.fileExists(atPath: install.path) { try fm.removeItem(at: install) }
        try fm.createDirectory(at: install, withIntermediateDirectories: false)
        for object in Self.objects where object.kind == "config" {
            let relative = "Data/config/\(object.key.prefix(2))/\(object.key.dropFirst(2).prefix(2))/\(object.key)"
            let target = install.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: downloads.appendingPathComponent(object.key), to: target)
        }
        progress(.init(message: "Building the streaming game data…", completedBytes: total, totalBytes: total, bytesPerSecond: 0))
        let storage = Self.objects.filter { $0.kind == "data" }.map { CASCObject(key: $0.key, file: downloads.appendingPathComponent($0.key)) }
        try CASCStorage.create(in: install.appendingPathComponent("Data/data"), objects: storage)
        try Self.buildInfo(locale: locale).write(to: install.appendingPathComponent(".fsbuild"), atomically: true, encoding: .utf8)
        try cancellation.check()
        let stagedGame = try core.finishCleanInstall(in: install, locale: locale) { message in
            progress(.init(message: message, completedBytes: total, totalBytes: total, bytesPerSecond: 0))
        }
        try cancellation.check()
        guard !fm.fileExists(atPath: destination.path) else { throw LauncherFailure("The destination folder appeared during installation. Choose another folder.") }
        try fm.moveItem(at: install, to: destination)
        // finishCleanInstall already validated this exact tree. After its atomic
        // move the transaction is committed; do not expose a new throwing step.
        let product = destination.appendingPathComponent("_midnight_",isDirectory:true)
        let game = GameInstallation(root:destination, product:product,
                                    app:product.appendingPathComponent("World of Warcraft.app",isDirectory:true),
                                    version:stagedGame.version)
        // Download cache is owned by this completed transaction, never user Data.
        try? fm.removeItem(at: stage)
        progress(.init(message: "Installed. Click Play; the game streams additional world assets from Firestorm as needed.", completedBytes: total, totalBytes: total, bytesPerSecond: 0))
        return game
    }

    static func buildInfo(locale: String) -> String {
        let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0"
        let tags = "OSX x86_64 arm64 EU \(locale) speech:OSX x86_64 arm64 EU \(locale) text"
        return header + "\n" + ["eu", "1", build, cdn, "", "", "tpr/wow", "57.129.6.7:105", server, tags, "", "", GameInstallation.supportedVersion, keyring, "wow"].joined(separator: "|") + "\n"
    }

    private static func validate(_ file: URL, object: RemoteObject) throws {
        let size = ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value
        guard size == object.size else { throw LauncherFailure("Incomplete download: \(object.title). Click Install to resume.") }
        if object.kind == "config" {
            let data = try Data(contentsOf: file)
            guard md5(data) == object.key else { throw LauncherFailure("The downloaded \(object.title) failed its checksum.") }
        } else { try validateBLTE(file, key: object.key) }
    }
    private static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// BLTE keys hash the encoding header, with MD5 checksums on each payload
    /// chunk. Headerless encodings hash the entire object instead.
    private static func validateBLTE(_ file: URL, key: String) throws {
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }
        guard let initial = try fileHandle.read(upToCount: 12), initial.count == 12, initial.prefix(4) == Data("BLTE".utf8) else {
            throw LauncherFailure("The CDN returned an invalid game data object.")
        }
        func be32(_ data: Data, _ offset: Int) -> UInt32 { data[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        let headerSize = Int(be32(initial, 4))
        if headerSize == 0 {
            try fileHandle.seek(toOffset: 0)
            var hasher = Insecure.MD5()
            while let data = try fileHandle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == key else { throw LauncherFailure("Game data checksum mismatch.") }
            return
        }
        guard headerSize >= 12, headerSize <= 32 * 1024 * 1024, initial[8] == 0x0f else { throw LauncherFailure("Unsupported game data header.") }
        try fileHandle.seek(toOffset: 0)
        guard let header = try fileHandle.read(upToCount: headerSize), header.count == headerSize, md5(header) == key else { throw LauncherFailure("Game data header checksum mismatch.") }
        let count = Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
        guard count > 0, 12 + 24 * count == headerSize else { throw LauncherFailure("Invalid game data chunk table.") }
        for i in 0..<count {
            let offset = 12 + 24 * i
            let size = Int(be32(header, offset))
            guard size > 0 else { throw LauncherFailure("Invalid game data chunk size.") }
            var remaining = size
            var hasher = Insecure.MD5()
            while remaining > 0 {
                guard let data = try fileHandle.read(upToCount: min(4 * 1024 * 1024, remaining)), !data.isEmpty else { throw LauncherFailure("Game data chunk is truncated.") }
                hasher.update(data: data); remaining -= data.count
            }
            guard Data(hasher.finalize()) == header[(offset+8)..<(offset+24)] else { throw LauncherFailure("Game data chunk checksum mismatch.") }
        }
        guard (try fileHandle.read(upToCount: 1) ?? Data()).isEmpty else { throw LauncherFailure("Unexpected bytes after the game data object.") }
    }
}

