import Foundation
import Darwin

/// Replaces only the launcher bundle. Game installations live outside this
/// transaction and are never inspected or modified by the updater.
enum LauncherUpdateInstaller {
    struct PreparedUpdate {
        let stagedAppURL: URL
        let targetAppURL: URL
        let workDirectory: URL
        let expectedVersion: String
        var logURL: URL { workDirectory.appendingPathComponent("update.log") }

        /// Start before terminating NSApp. A separate, HUP-resistant process
        /// waits for this process to exit before moving the running bundle.
        func startReplacement(parentPID: Int32 = getpid()) throws {
            guard parentPID > 1 else { throw LauncherFailure(L("Could not start the launcher update.")) }
            let targetVersion = try LauncherUpdateInstaller.validateUpgrade(target: targetAppURL, expectedVersion: expectedVersion)
            let fm = FileManager.default
            let script = workDirectory.appendingPathComponent("replace-launcher.sh")
            try Data(LauncherUpdateInstaller.replacementScript.utf8).write(to: script, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            guard fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LauncherFailure(L("Could not create the launcher update log."))
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = ["/bin/sh", script.path, String(parentPID), targetAppURL.path,
                                 stagedAppURL.path, workDirectory.appendingPathComponent("Previous.app").path,
                                 workDirectory.path, targetVersion]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            process.currentDirectoryURL = workDirectory
            try process.run()
        }

        /// Use when preparation succeeded but the user keeps the current app.
        func discard() { try? FileManager.default.removeItem(at: workDirectory) }
    }

    /// Extraction, signature verification and copying are blocking operations;
    /// call this method away from the main thread.
    static func prepare(archiveURL: URL, expectedVersion: String,
                        installedAppURL: URL = Bundle.main.bundleURL) throws -> PreparedUpdate {
        let fm = FileManager.default
        let target = installedAppURL.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard target.isFileURL, target.pathExtension == "app",
              target == target.resolvingSymlinksInPath(),
              !target.pathComponents.contains("AppTranslocation"),
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path),
              (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true else {
            throw LauncherFailure(L("Move Firestorm Launcher to Applications or another writable folder before updating."))
        }
        _ = try validateUpgrade(target: target, expectedVersion: expectedVersion)
        try validateArchive(at: archiveURL)
        let work = parent.appendingPathComponent(".firestorm-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: work) } }
        let extracted = work.appendingPathComponent("Extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extracted.path])
        try validateExtractedTree(extracted)
        let candidate = extracted.appendingPathComponent("Firestorm-Launcher/Firestorm Launcher.app", isDirectory: true)
        let info = try bundleInfo(candidate)
        guard info["CFBundleIdentifier"] as? String == "local.firestorm.launcher",
              info["CFBundleShortVersionString"] as? String == expectedVersion,
              info["CFBundleExecutable"] as? String == "FirestormLauncher",
              info["CFBundlePackageType"] as? String == "APPL" else {
            throw LauncherFailure(L("The downloaded archive does not contain the expected launcher version."))
        }
        let executable = candidate.appendingPathComponent("Contents/MacOS/FirestormLauncher")
        guard (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.isExecutableFile(atPath: executable.path) else {
            throw LauncherFailure(L("The downloaded launcher executable is invalid."))
        }
        // Ad-hoc signing is used by the project; this checks archive integrity,
        // while release provenance and SHA-256 are checked by the downloader.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", candidate.path])
        for architecture in ["arm64", "x86_64"] {
            try run("/usr/bin/lipo", ["-verify_arch", architecture, executable.path])
        }
        let staged = work.appendingPathComponent("Updated.app", isDirectory: true)
        try fm.moveItem(at: candidate, to: staged)
        try fm.removeItem(at: extracted)
        prepared = true
        return PreparedUpdate(stagedAppURL: staged, targetAppURL: target, workDirectory: work, expectedVersion: expectedVersion)
    }

    /// Inspect the ZIP before allowing ditto to write any paths. The project's
    /// release is a small ordinary ZIP; ZIP64, links and special files are not
    /// required and are deliberately refused.
    static func validateArchive(at archiveURL: URL) throws {
        guard archiveURL.isFileURL else { throw invalidArchive() }
        let reader = try FileHandle(forReadingFrom: archiveURL)
        defer { try? reader.close() }
        let fileSize = try reader.seekToEnd()
        guard fileSize >= 22, fileSize <= 512 * 1_024 * 1_024 else { throw invalidArchive() }
        let tailSize = Int(min(fileSize, 65_557))
        try reader.seek(toOffset: fileSize - UInt64(tailSize))
        let tail = try reader.read(upToCount: tailSize) ?? Data()
        guard tail.count == tailSize else { throw invalidArchive() }
        var ending: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, offset) == 0x06054b50,
               let comment = u16(tail, offset + 20), offset + 22 + Int(comment) == tail.count {
                ending = offset
                break
            }
        }
        guard let ending,
              u16(tail, ending + 4) == 0, u16(tail, ending + 6) == 0,
              let count = u16(tail, ending + 10), count > 0, count < 20_000,
              u16(tail, ending + 8) == count,
              let directorySize = u32(tail, ending + 12), directorySize > 0, directorySize <= 16 * 1_024 * 1_024,
              let directoryOffset = u32(tail, ending + 16), directoryOffset != UInt32.max,
              UInt64(directoryOffset) + UInt64(directorySize) == fileSize - UInt64(tailSize) + UInt64(ending) else {
            throw invalidArchive()
        }
        try reader.seek(toOffset: UInt64(directoryOffset))
        let directory = try reader.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else { throw invalidArchive() }
        var position = 0
        var names = Set<String>()
        var unpacked: UInt64 = 0
        var localRanges: [Range<UInt64>] = []
        for _ in 0..<count {
            guard u32(directory, position) == 0x02014b50,
                  let flags = u16(directory, position + 8), flags & 0x0041 == 0,
                  let method = u16(directory, position + 10), method == 0 || method == 8,
                  let compressed = u32(directory, position + 20), compressed != UInt32.max,
                  let uncompressed = u32(directory, position + 24), uncompressed <= 1_024 * 1_024 * 1_024,
                  let nameLength = u16(directory, position + 28), nameLength > 0,
                  let extraLength = u16(directory, position + 30),
                  let commentLength = u16(directory, position + 32),
                  u16(directory, position + 34) == 0,
                  let attributes = u32(directory, position + 38),
                  let localOffset = u32(directory, position + 42), localOffset != UInt32.max else {
                throw invalidArchive()
            }
            let end = position + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard end <= directory.count else { throw invalidArchive() }
            let nameBytes = directory.subdata(in: (position + 46)..<(position + 46 + Int(nameLength)))
            guard let name = String(data: nameBytes, encoding: .utf8), validArchivePath(name),
                  names.insert(name.decomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw invalidArchive()
            }
            let kind = (attributes >> 16) & 0xf000
            guard kind == 0 || kind == 0x4000 || kind == 0x8000,
                  kind != 0x4000 || name.hasSuffix("/"),
                  kind != 0x8000 || !name.hasSuffix("/") else { throw invalidArchive() }
            unpacked += UInt64(uncompressed)
            guard unpacked <= 2 * 1_024 * 1_024 * 1_024,
                  UInt64(localOffset) + 30 <= UInt64(directoryOffset) else { throw invalidArchive() }
            try reader.seek(toOffset: UInt64(localOffset))
            let local = try reader.read(upToCount: 30) ?? Data()
            guard u32(local, 0) == 0x04034b50, u16(local, 6) == flags, u16(local, 8) == method,
                  u16(local, 26) == nameLength, let localExtra = u16(local, 28) else { throw invalidArchive() }
            let localName = try reader.read(upToCount: Int(nameLength)) ?? Data()
            let dataEnd = UInt64(localOffset) + 30 + UInt64(nameLength) + UInt64(localExtra) + UInt64(compressed)
            guard localName == nameBytes, dataEnd <= UInt64(directoryOffset) else { throw invalidArchive() }
            localRanges.append(UInt64(localOffset)..<dataEnd)
            position = end
        }
        guard position == directory.count else { throw invalidArchive() }
        var previousEnd: UInt64 = 0
        for range in localRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= previousEnd else { throw invalidArchive() }
            previousEnd = range.upperBound
        }
    }

    private static func validArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"),
              path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if path.hasSuffix("/") { parts.removeLast() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts[0] == "Firestorm-Launcher" || parts[0] == "__MACOSX" else { return false }
        return true
    }

    private static func u16(_ bytes: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 2 else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: Data, _ offset: Int) -> UInt32? {
        guard let low = u16(bytes, offset), let high = u16(bytes, offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    private static func invalidArchive() -> LauncherFailure {
        LauncherFailure(L("The launcher update archive is invalid or contains unsafe paths."))
    }

    private static func bundleInfo(_ app: URL) throws -> [String: Any] {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let size = try? info.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: info),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LauncherFailure(L("The launcher bundle is invalid."))
        }
        return value
    }

    /// Read the installed bundle from disk, rather than trusting the running
    /// process's version: another launcher may already have upgraded this path.
    private static func validateUpgrade(target: URL, expectedVersion: String) throws -> String {
        let info = try bundleInfo(target)
        guard info["CFBundleIdentifier"] as? String == "local.firestorm.launcher",
              let installedString = info["CFBundleShortVersionString"] as? String,
              let installed = LauncherVersion(rawString: installedString),
              let expected = LauncherVersion(rawString: expectedVersion) else {
            throw LauncherFailure(L("This copy of the launcher cannot install updates automatically."))
        }
        guard expected > installed else {
            throw LauncherFailure(L("A newer or equal launcher version is already installed. Check for updates again."))
        }
        return installedString
    }

    private static func validateExtractedTree(_ directory: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { throw invalidArchive() }
        for case let item as URL in items {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true,
                  item.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else { throw invalidArchive() }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LauncherFailure(LF("The launcher update could not complete the %@ step.", URL(fileURLWithPath: executable).lastPathComponent))
        }
    }

    // Every path is passed as a positional argument rather than interpolated
    // into shell source, including installation folders with quotes or spaces.
    static let replacementScript = #"""
    #!/bin/sh
    set -u
    parent="$1"
    target="$2"
    staged="$3"
    backup="$4"
    work="$5"
    previous_version="$6"
    count=0
    while /bin/kill -0 "$parent" 2>/dev/null; do
      count=$((count + 1))
      if [ "$count" -ge 120 ]; then
        echo 'The launcher did not exit; the update was not installed.'
        exit 1
      fi
      /bin/sleep 1
    done
    current_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist" 2>/dev/null) || exit 1
    if [ "$current_version" != "$previous_version" ]; then
      echo 'The installed launcher changed while waiting; the update was not installed.'
      /usr/bin/open "$target" || true
      exit 1
    fi
    if ! /bin/mv "$target" "$backup"; then
      echo 'Could not back up the installed launcher.'
      exit 1
    fi
    if /bin/mv "$staged" "$target"; then
      if /usr/bin/open "$target"; then
        /bin/rm -rf "$backup"
        /bin/rm -rf "$work"
        exit 0
      fi
      echo 'Could not reopen the updated launcher; restoring the previous version.'
      if ! /bin/mv "$target" "$staged"; then
        echo 'Could not move the failed update; the previous launcher is retained in Previous.app.'
        exit 1
      fi
    fi
    if /bin/mv "$backup" "$target"; then
      /usr/bin/open "$target" || true
      echo 'The previous launcher was restored.'
      exit 1
    fi
    echo 'Could not restore the launcher; the previous bundle is retained in Previous.app.'
    exit 1
    """#
}
