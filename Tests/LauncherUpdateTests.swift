import Foundation
import CryptoKit

private struct LauncherUpdateTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic GitHub metadata and private temporary files only. These checks
/// never download an update, install an app, or launch a replacement helper.
enum LauncherUpdateTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw LauncherUpdateTestFailure(description: message) }
        }
        func rejects(_ message: String, _ block: () throws -> Void) throws {
            checks += 1
            do { try block() } catch { return }
            throw LauncherUpdateTestFailure(description: "Expected rejection: " + message)
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("firestorm-update-tests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }

        let versionPairs = [
            ("1.2.0", "1.10.0"), ("1.9.99", "1.10.0"), ("1.99.99", "2.0.0"),
            ("1.2.9", "1.2.10"), ("0.9.0", "1.0.0"),
        ]
        for (older, newer) in versionPairs {
            guard let old = LauncherVersion(rawString: older), let new = LauncherVersion(rawString: newer) else {
                throw LauncherUpdateTestFailure(description: "Numeric release versions must parse")
            }
            try expect(old < new && !(new < old), "Release versions compare numeric components: \(older) < \(newer)")
        }
        try expect(LauncherVersion(rawString: "v1.2.3") == LauncherVersion(rawString: "1.2.3"), "The conventional Git tag prefix does not change version ordering")
        try expect(LauncherVersion(rawString: "v1.2.3")?.description == "1.2.3", "A version description omits its optional tag prefix")
        for version in ["", "v", "1", "1.2", "1.2.3.4", "1.a.3", "-1.2.3", "1.2.-3", "01.2.3", "1.2.3-beta", "1.2.3+build", "v1.2.3evil", "999999999999999999999999999999.2.3"] {
            try expect(LauncherVersion(rawString: version) == nil, "Malformed or nonstable versions are not installable: \(version)")
        }

        let payload = Data("Synthetic launcher archive payload".utf8)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let assetName = "Firestorm-Launcher-1.2.0-macOS-Universal.zip"
        let releaseURL = "https://github.com/kolyanok/firestorm-macos-launcher/releases/tag/v1.2.0"
        let assetURL = "https://github.com/kolyanok/firestorm-macos-launcher/releases/download/v1.2.0/" + assetName
        let asset: [String: Any] = [
            "name": assetName, "size": payload.count, "state": "uploaded", "content_type": "application/zip",
            "browser_download_url": assetURL, "digest": "sha256:" + checksum,
        ]
        let metadata: [String: Any] = [
            "tag_name": "v1.2.0", "name": "Launcher 1.2.0", "draft": false, "prerelease": false,
            "html_url": releaseURL, "assets": [asset],
        ]
        func decode(_ object: [String: Any], current: String = "1.1.9") throws -> LauncherUpdateRelease? {
            try LauncherUpdateService.decodeRelease(JSONSerialization.data(withJSONObject: object), currentVersion: current)
        }
        func withAsset(_ key: String, _ value: Any?) -> [String: Any] {
            var changed = asset
            changed[key] = value
            var release = metadata
            release["assets"] = [changed]
            return release
        }
        guard let update = try decode(metadata) else {
            throw LauncherUpdateTestFailure(description: "A newer stable release with the exact Universal ZIP must be available")
        }
        try expect(update.version.description == "1.2.0" && update.tagName == "v1.2.0", "A stable release preserves its normalized version and original Git tag")
        try expect(update.releaseURL.absoluteString == releaseURL && update.assetURL.absoluteString == assetURL, "The release page and Universal ZIP use the trusted repository URLs")
        try expect(update.assetName == assetName && update.assetSize == Int64(payload.count) && update.digestSHA256 == checksum, "Expected asset name, complete file size, and SHA256 come from one matching asset")
        try expect(try decode(metadata, current: "1.2.0") == nil, "The installed release is never offered as its own update")
        try expect(try decode(metadata, current: "2.0.0") == nil, "A release older than the installed app cannot downgrade it")
        for key in ["draft", "prerelease"] {
            var changed = metadata
            changed[key] = true
            try expect(try decode(changed) == nil, "A \(key) release is never offered for automatic installation")
        }
        for contents in [Data("{malformed".utf8), Data("<html>GitHub unavailable</html>".utf8), Data("null".utf8)] {
            try rejects("Malformed release metadata is not an up-to-date result") {
                _ = try LauncherUpdateService.decodeRelease(contents, currentVersion: "1.1.9")
            }
        }
        for tag in ["1.2", "v1.2.0-beta", "v1.2.0/../../other"] {
            var changed = metadata
            changed["tag_name"] = tag
            try rejects("Invalid release tags cannot define update paths") { _ = try decode(changed) }
        }
        var noAsset = metadata
        noAsset["assets"] = []
        try rejects("A release without a suitable asset is not installable") { _ = try decode(noAsset) }
        try rejects("A platform or version mismatched ZIP is not substituted") {
            _ = try decode(withAsset("name", "Firestorm-Launcher-1.2.0-Windows.zip"))
        }
        var ambiguousAsset = metadata
        ambiguousAsset["assets"] = [asset, asset]
        try rejects("Ambiguous duplicate update assets cannot select an arbitrary download") { _ = try decode(ambiguousAsset) }
        for target in [
            assetURL.replacingOccurrences(of: "https:", with: "http:"),
            assetURL.replacingOccurrences(of: "github.com/", with: "github.com.evil.invalid/"),
            assetURL.replacingOccurrences(of: "github.com/", with: "user:password@github.com/"),
            assetURL.replacingOccurrences(of: "github.com/", with: "github.com:8080/"),
            assetURL.replacingOccurrences(of: "/kolyanok/", with: "/other-owner/"),
            assetURL.replacingOccurrences(of: "/v1.2.0/", with: "/v9.9.9/"),
            assetURL + "?download=1", assetURL + "#other", "file:///tmp/update.zip",
        ] {
            try rejects("An asset URL outside the exact trusted release path is rejected") {
                _ = try decode(withAsset("browser_download_url", target))
            }
        }
        var wrongPage = metadata
        wrongPage["html_url"] = "https://github.com/other-owner/firestorm-macos-launcher/releases/tag/v1.2.0"
        try rejects("The manual release link cannot redirect users to a different repository") { _ = try decode(wrongPage) }
        for badSize in [0, -1, 3.5, true, "33"] as [Any] {
            try rejects("Invalid expected asset sizes are not accepted") { _ = try decode(withAsset("size", badSize)) }
        }
        for digest in ["sha1:" + checksum, "sha256:xyz", "sha256:" + String(repeating: "a", count: 63), "sha256:" + String(repeating: "g", count: 64)] {
            try rejects("Malformed or unsupported asset digests cannot authorize installation") { _ = try decode(withAsset("digest", digest)) }
        }
        let manualOnly = try decode(withAsset("digest", nil))
        try expect(manualOnly != nil && manualOnly?.digestSHA256 == nil, "A release without GitHub SHA256 remains available only for the manual page fallback")
        try expect(try decode(withAsset("digest", "sha256:" + checksum.uppercased()))?.digestSHA256 == checksum,
                   "SHA256 hex is normalized consistently before complete-file verification")

        let downloaded = temporary.appendingPathComponent("download.zip")
        try payload.write(to: downloaded)
        try LauncherUpdateService.validateDownloadedFile(downloaded, release: update)
        checks += 1
        var sameSizeTampered = payload
        sameSizeTampered[0] ^= 1
        try sameSizeTampered.write(to: downloaded)
        try rejects("A same-size modified download fails SHA256 validation") {
            try LauncherUpdateService.validateDownloadedFile(downloaded, release: update)
        }
        try payload.dropLast().write(to: downloaded)
        try rejects("A truncated download cannot pass its expected complete size") {
            try LauncherUpdateService.validateDownloadedFile(downloaded, release: update)
        }
        try (payload + Data([0])).write(to: downloaded)
        try rejects("An oversized download cannot pass its expected complete size") {
            try LauncherUpdateService.validateDownloadedFile(downloaded, release: update)
        }
        try payload.write(to: downloaded)
        if let manualOnly {
            try rejects("Automatic installation requires a digest even when the asset size matches") {
                try LauncherUpdateService.validateDownloadedFile(downloaded, release: manualOnly)
            }
        }
        try fm.removeItem(at: downloaded)

        let archive = temporary.appendingPathComponent("fixture.zip")
        func validate(_ bytes: Data) throws {
            try bytes.write(to: archive)
            try LauncherUpdateInstaller.validateArchive(at: archive)
        }
        let validArchive = zip([
            ZIPEntry(name: "Firestorm-Launcher/", data: Data(), mode: 0o040755),
            ZIPEntry(name: "Firestorm-Launcher/readme.txt"),
            ZIPEntry(name: "Firestorm-Launcher/Firestorm Launcher.app/Contents/Resources/Русский.txt"),
        ])
        try validate(validArchive)
        try expect(try Data(contentsOf: archive) == validArchive, "Archive validation leaves the downloaded ZIP unchanged")
        try expect(try fm.contentsOfDirectory(atPath: temporary.path) == ["fixture.zip"], "Archive validation never extracts or installs archive contents")
        try validate(zip([
            ZIPEntry(name: "Firestorm-Launcher/readme.txt"),
            ZIPEntry(name: "__MACOSX/Firestorm-Launcher/._readme.txt"),
        ]))
        checks += 1

        for name in [
            "../outside.txt", "/tmp/firestorm-outside.txt", "Firestorm-Launcher/../outside.txt",
            "Firestorm-Launcher/sub/../../outside.txt", "Firestorm-Launcher\\..\\outside.txt",
            "Firestorm-Launcher/unsafe\nname", "Firestorm-Launcher/unsafe\0name",
            "Other Launcher.app/Contents/MacOS/Launcher",
        ] {
            try rejects("Unsafe ZIP extraction path: \(name.debugDescription)") {
                try validate(zip([ZIPEntry(name: name)]))
            }
        }
        try rejects("Duplicate entries can overwrite an already validated path") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/same"), ZIPEntry(name: "Firestorm-Launcher/same")]))
        }
        try rejects("Case variants cannot overwrite the same macOS destination") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/File"), ZIPEntry(name: "Firestorm-Launcher/file")]))
        }
        try rejects("Canonical Unicode variants cannot overwrite the same macOS destination") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/é"), ZIPEntry(name: "Firestorm-Launcher/e\u{301}")]))
        }
        for mode in [UInt32(0o120777), UInt32(0o140777), UInt32(0o020666)] {
            try rejects("A ZIP entry must not create a symlink or special file") {
                try validate(zip([ZIPEntry(name: "Firestorm-Launcher/unsafe", mode: mode)]))
            }
        }
        try rejects("Encrypted ZIP entries cannot be audited before extraction") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/encrypted", flags: 1)]))
        }
        try rejects("Unsupported ZIP compression cannot be safely extracted") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/compressed", method: 99)]))
        }
        try rejects("A multipart archive cannot refer outside the downloaded ZIP") {
            try validate(zip([ZIPEntry(name: "Firestorm-Launcher/readme.txt")], disk: 1))
        }
        try rejects("Truncated ZIP metadata is rejected") { try validate(Data(validArchive.dropLast(12))) }
        try rejects("An HTML/error download is not an update archive") { try validate(Data("<html>Unavailable</html>".utf8)) }
        var mismatchedName = zip([ZIPEntry(name: "Firestorm-Launcher/readme.txt")])
        mismatchedName[30] = 0x58
        try rejects("Local and central ZIP headers must name the same destination") { try validate(mismatchedName) }

        // Exercise the real replacement shell program with only its opener
        // substituted. All source/destination bundles are private test folders.
        func shellQuote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func app(_ directory: URL, marker: String, version: String) throws {
            let contents = directory.appendingPathComponent("Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "local.firestorm.launcher", "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data(marker.utf8).write(to: contents.appendingPathComponent("marker.txt"))
        }
        func marker(_ directory: URL) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        }
        func helperFixture(_ name: String) throws -> ReplacementFixture {
            let root = temporary.appendingPathComponent(name + " path's \"quoted\" $value")
            let work = root.appendingPathComponent("Private work's folder")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let fixture = ReplacementFixture(
                root: root, target: root.appendingPathComponent("Firestorm Launcher's \"Test\".app"),
                staged: work.appendingPathComponent("Updated.app"), backup: work.appendingPathComponent("Previous.app"),
                work: work, opener: root.appendingPathComponent("opener's stub.sh"),
                openLog: root.appendingPathComponent("opened-markers.log"), helperLog: root.appendingPathComponent("helper.log"))
            try app(fixture.target, marker: "old", version: "1.1.11")
            try app(fixture.staged, marker: "new", version: "1.1.12")
            let opener = #"""
            #!/bin/sh
            marker=$(/bin/cat "$1/Contents/marker.txt") || exit 90
            printf '%s\n' "$marker" >> "$UPDATE_TEST_OPEN_LOG"
            if [ "$UPDATE_TEST_FAIL_NEW" = 1 ] && [ "$marker" = new ]; then exit 1; fi
            exit 0
            """#
            try Data(opener.utf8).write(to: fixture.opener)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.opener.path)
            return fixture
        }
        func runHelper(_ fixture: ReplacementFixture, parentPID: Int32 = Int32.max,
                       failNew: Bool = false, whileWaiting: (() throws -> Void)? = nil) throws -> Int32 {
            let original = LauncherUpdateInstaller.replacementScript
            try expect(original.contains("/usr/bin/open"), "The production helper contains the opener being replaced by this fixture")
            let source = original.replacingOccurrences(of: "/usr/bin/open", with: shellQuote(fixture.opener.path))
            let script = fixture.work.appendingPathComponent("replacement.sh")
            try Data(source.utf8).write(to: script)
            try Data().write(to: fixture.helperLog)
            let output = try FileHandle(forWritingTo: fixture.helperLog)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(parentPID), fixture.target.path, fixture.staged.path,
                                 fixture.backup.path, fixture.work.path, "1.1.11"]
            var environment = ProcessInfo.processInfo.environment
            environment["UPDATE_TEST_OPEN_LOG"] = fixture.openLog.path
            environment["UPDATE_TEST_FAIL_NEW"] = failNew ? "1" : "0"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.currentDirectoryURL = fixture.root
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            try whileWaiting?()
            guard ended.wait(timeout: .now() + 5) == .success else {
                throw LauncherUpdateTestFailure(description: "The private replacement helper did not finish promptly")
            }
            process.waitUntilExit()
            return process.terminationStatus
        }
        func openedMarkers(_ fixture: ReplacementFixture) throws -> [String] {
            try String(contentsOf: fixture.openLog, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        let success = try helperFixture("Success")
        let sibling = success.root.appendingPathComponent("Game data stays here.txt")
        try Data("untouched".utf8).write(to: sibling)
        try expect(try runHelper(success) == 0, "The replacement helper completes a normal update successfully")
        try expect(try marker(success.target) == "new", "The staged bundle becomes the installed launcher")
        try expect(try openedMarkers(success) == ["new"], "The helper opens only the newly installed fixture bundle")
        try expect(!fm.fileExists(atPath: success.work.path), "A successful update removes its backup and staging work directory")
        try expect(try String(contentsOf: sibling, encoding: .utf8) == "untouched", "The replacement transaction leaves neighboring game/user data untouched")

        let failedOpen = try helperFixture("Open failure")
        try expect(try runHelper(failedOpen, failNew: true) != 0, "Failure to reopen the update reports an unsuccessful installation")
        try expect(try marker(failedOpen.target) == "old" && marker(failedOpen.staged) == "new", "An opener failure restores the original bundle and retains the failed staged update")
        try expect(try openedMarkers(failedOpen) == ["new", "old"], "The rollback reopens the restored original fixture")
        try expect(!fm.fileExists(atPath: failedOpen.backup.path) && fm.fileExists(atPath: failedOpen.work.path), "Rollback restores the backup without deleting the diagnostic work directory")

        let missingStaged = try helperFixture("Missing staged")
        try fm.removeItem(at: missingStaged.staged)
        try expect(try runHelper(missingStaged) != 0, "A missing staged app fails the replacement transaction")
        try expect(try marker(missingStaged.target) == "old", "A missing staged app still restores the original after its backup rename")
        try expect(try openedMarkers(missingStaged) == ["old"], "Only the restored original is opened when the staged app is missing")
        try expect(!fm.fileExists(atPath: missingStaged.backup.path), "A successful missing-staged rollback leaves the original at its installed path")

        let changedTarget = try helperFixture("Changed target")
        try app(changedTarget.target, marker: "changed", version: "1.1.12")
        try expect(try runHelper(changedTarget) != 0, "An installed version changed since preparation is never replaced")
        try expect(try marker(changedTarget.target) == "changed" && marker(changedTarget.staged) == "new", "A concurrent target-version change preserves both the current and staged bundles")
        try expect(!fm.fileExists(atPath: changedTarget.backup.path), "The version guard runs before the original bundle is renamed")
        try expect(try openedMarkers(changedTarget) == ["changed"], "A skipped update reopens the existing fixture bundle")

        let waiting = try helperFixture("Parent wait")
        let parentInput = Pipe()
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/cat")
        parent.standardInput = parentInput
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() } }
        try expect(try runHelper(waiting, parentPID: parent.processIdentifier, whileWaiting: {
            Thread.sleep(forTimeInterval: 0.05)
            try expect(parent.isRunning, "The parent-wait fixture is still alive before it is released")
            try expect(try marker(waiting.target) == "old" && marker(waiting.staged) == "new", "The helper preserves both bundles while the parent process is alive")
            try expect(!fm.fileExists(atPath: waiting.openLog.path), "The helper does not reopen the launcher while its parent is running")
            try parentInput.fileHandleForWriting.close()
            parent.waitUntilExit()
        }) == 0, "The helper completes promptly after its parent exits")
        try expect(try marker(waiting.target) == "new" && openedMarkers(waiting) == ["new"], "The waiting helper installs and opens the update only after parent exit")
        return checks
    }

    private struct ReplacementFixture {
        let root: URL
        let target: URL
        let staged: URL
        let backup: URL
        let work: URL
        let opener: URL
        let openLog: URL
        let helperLog: URL
    }

    private struct ZIPEntry {
        let name: String
        var data = Data("fixture".utf8)
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var mode: UInt32 = 0o100644
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var result: UInt32 = 0xffffffff
        for byte in bytes {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                result = (result >> 1) ^ (result & 1 == 1 ? 0xedb88320 : 0)
            }
        }
        return result ^ 0xffffffff
    }

    private static func zip(_ entries: [ZIPEntry], disk: UInt16 = 0) -> Data {
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        var result = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(result.count)
            let name = Data(entry.name.utf8)
            let checksum = crc32(entry.data)
            append(UInt32(0x04034b50), to: &result)
            append(UInt16(20), to: &result)
            append(entry.flags, to: &result)
            append(entry.method, to: &result)
            append(UInt16(0), to: &result) // DOS time
            append(UInt16(0), to: &result) // DOS date
            append(checksum, to: &result)
            append(UInt32(entry.data.count), to: &result)
            append(UInt32(entry.data.count), to: &result)
            append(UInt16(name.count), to: &result)
            append(UInt16(0), to: &result)
            result.append(name)
            result.append(entry.data)

            append(UInt32(0x02014b50), to: &central)
            append(UInt16(0x0314), to: &central) // UNIX creator, ZIP 2.0
            append(UInt16(20), to: &central)
            append(entry.flags, to: &central)
            append(entry.method, to: &central)
            append(UInt16(0), to: &central)
            append(UInt16(0), to: &central)
            append(checksum, to: &central)
            append(UInt32(entry.data.count), to: &central)
            append(UInt32(entry.data.count), to: &central)
            append(UInt16(name.count), to: &central)
            append(UInt16(0), to: &central) // extra field length
            append(UInt16(0), to: &central) // comment length
            append(UInt16(0), to: &central) // disk number
            append(UInt16(0), to: &central) // internal attributes
            append(entry.mode << 16, to: &central)
            append(offset, to: &central)
            central.append(name)
        }
        let centralOffset = UInt32(result.count)
        result.append(central)
        append(UInt32(0x06054b50), to: &result)
        append(disk, to: &result)
        append(disk, to: &result)
        append(UInt16(entries.count), to: &result)
        append(UInt16(entries.count), to: &result)
        append(UInt32(central.count), to: &result)
        append(centralOffset, to: &result)
        append(UInt16(0), to: &result)
        return result
    }
}
