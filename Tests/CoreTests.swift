import Foundation
import CryptoKit
import Darwin

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let value): return value }
    }
}

private let fm = FileManager.default
private var assertions = 0

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw TestFailure.assertion(message) }
}

private func expectThrows(_ message: String, _ block: () throws -> Void) throws {
    assertions += 1
    do { try block() } catch { return }
    throw TestFailure.assertion("Expected rejection: " + message)
}

private func checkLocalization() throws {
    try expect(LauncherLocalization.resolvedLanguage(preference: "ru", preferredLanguages: ["en-US"]) == "ru", "Explicit Russian overrides the system language")
    try expect(LauncherLocalization.resolvedLanguage(preference: "en", preferredLanguages: ["ru-RU"]) == "en", "Explicit English overrides the system language")
    try expect(LauncherLocalization.resolvedLanguage(preference: "auto", preferredLanguages: ["ru-RU"]) == "ru", "Automatic Russian language selection")
    try expect(LauncherLocalization.resolvedLanguage(preference: nil, preferredLanguages: ["fr-FR"]) == "en", "Unsupported system languages fall back to English")
    try expect(LauncherLocalization.resolvedLanguage(preference: "invalid", preferredLanguages: []) == "en", "Unknown saved preferences have a safe fallback")
    try expect(LauncherLocalization.text("Play", language: "en") == "Play", "English text is preserved")
    try expect(LauncherLocalization.text("Play", language: "ru") == "Играть", "Russian button translation")
    try expect(LauncherLocalization.text("Unknown key", language: "ru") == "Unknown key", "Missing translation has an English fallback")
    let placeholders = try NSRegularExpression(pattern: "%[0-9$.*+\\-]*[a-zA-Z@]")
    func formats(_ text: String) -> [String] {
        placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }.sorted()
    }
    for (english, russian) in LauncherLocalization.russian {
        try expect(!russian.isEmpty && formats(english) == formats(russian), "Translation preserves format arguments for \(english)")
    }
    let format = LauncherLocalization.text("Install location: %@", language: "ru")
    try expect(String(format: format, "/tmp/Игра") == "Папка установки — /tmp/Игра", "Localized messages preserve Unicode paths")
}

private func run(_ executable: String, _ args: [String]) throws {
    let output = fm.temporaryDirectory.appendingPathComponent("firestorm-tests-output-" + UUID().uuidString)
    fm.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close(); try? fm.removeItem(at: output) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let detail = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        throw TestFailure.assertion("\(executable) failed: \(detail)")
    }
}

private func write(_ text: String, to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func digest(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
}

private func appFingerprint(_ app: URL) throws -> [String: String] {
    let enumerator = fm.enumerator(atPath: app.path)!
    var hashes: [String: String] = [:]
    for case let key as String in enumerator {
        let file = app.appendingPathComponent(key)
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            hashes[key] = try digest(file)
        }
    }
    return hashes
}

private func createApp(_ app: URL, origin: String, version: String = GameInstallation.supportedVersion) throws {
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("World of Warcraft")
    try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let info: [String: Any] = [
        "CFBundleIdentifier": "local.firestorm.testfixture",
        "CFBundleName": "World of Warcraft",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "World of Warcraft",
        "CFBundleVersion": version,
        "CFBundleShortVersionString": "12.0.7"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    try write(origin, to: app.appendingPathComponent("Contents/Resources/origin.txt"))
    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
}

private struct Fixture {
    let base: URL
    let root: URL
    let resources: URL
    let originalConfig = "SET portal \"old.example.test\"\nSET textLocale \"enUS\"\nSET audioLocale \"enUS\"\nSET gxWindow \"1\"\n# keep this comment\n"

    init(_ base: URL) throws {
        self.base = base
        root = base.appendingPathComponent("Source Client")
        resources = base.appendingPathComponent("Resources")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let keyA = String(repeating: "a", count: 32)
        let keyB = String(repeating: "b", count: 32)
        let header = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Install Key!HEX:16|IM Size!DEC:4|CDN Path!STRING:0|CDN Hosts!STRING:0|CDN Servers!STRING:0|Tags!STRING:0|Armadillo!STRING:0|Last Activated!STRING:0|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0"
        let entry = "eu|1|\(keyA)|\(keyB)|||tpr/wow|example.test|https://example.test|OSX arm64 EU ruRU|||12.0.7.68974||wow"
        try write(header + "\n" + entry + "\n", to: root.appendingPathComponent(".fsbuild"))
        for key in [keyA, keyB] {
            try write("test config\n", to: root.appendingPathComponent("Data/config/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)"))
        }
        try write("archive fixture", to: root.appendingPathComponent("Data/data/data.000"))
        try createApp(root.appendingPathComponent("_midnight_/World of Warcraft.app"), origin: "original client")
        try write(originalConfig, to: root.appendingPathComponent("_midnight_/WTF/Firestorm.wtf"))
        try write("private account fixture", to: root.appendingPathComponent("_midnight_/WTF/Account/private/saved.txt"))
        let payload = base.appendingPathComponent("Payload/World of Warcraft.app")
        try createApp(payload, origin: "bundled client")
        let payloadFiles = try appFingerprint(payload)
        guard payloadFiles["Contents/MacOS/World of Warcraft"] != nil else {
            throw TestFailure.assertion("Fixture fingerprint uses unexpected paths: \(payloadFiles.keys.sorted())")
        }
        let manifest: [String: Any] = ["version": GameInstallation.supportedVersion, "files": payloadFiles]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: resources.appendingPathComponent("client-manifest.json"))
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", payload.path, resources.appendingPathComponent("Client.zip").path])
    }
}

@main
struct CoreTests {
    static func main() {
        // Directory enumeration uses /private/var on macOS while Foundation's
        // symlink resolver can retain /var in restricted command sessions.
        let temporaryBase = fm.temporaryDirectory.path
        let canonicalBase = temporaryBase.hasPrefix("/var/") ? "/private" + temporaryBase : temporaryBase
        let temporary = URL(fileURLWithPath: canonicalBase, isDirectory: true)
            .appendingPathComponent("firestorm-launcher-tests-" + UUID().uuidString)
        do {
            try checkLocalization()
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }
            let fixture = try Fixture(temporary.appendingPathComponent("Primary"))
            let core = LauncherCore(resources: fixture.resources)
            let game = try GameInstallation.inspect(fixture.root)
            try expect(game.version == GameInstallation.supportedVersion, "Inspect supported version")
            try expect(try GameInstallation.inspect(game.product).root.path == game.root.path, "Inspect product folder")
            try expect(try GameInstallation.inspect(game.app).root.path == game.root.path, "Inspect app folder")
            try expect(try !core.check(game).patched, "Fresh client should not be prepared")

            let original = try appFingerprint(game.app)
            let originalBuild = try Data(contentsOf: game.root.appendingPathComponent(".fsbuild"))
            try core.prepare(game, locale: "ruRU", progress: { _ in })
            try expect(try core.check(game).patched, "Prepared app validates")
            let backupRoot = game.root.appendingPathComponent(".firestorm-launcher-backups")
            let backupsBefore = try fm.contentsOfDirectory(atPath: backupRoot.path).sorted()
            try core.prepare(game, locale: "ruRU", progress: { _ in })
            try expect(try fm.contentsOfDirectory(atPath: backupRoot.path).sorted() == backupsBefore, "Repeated preparation creates no redundant backup")
            let configURL = game.product.appendingPathComponent("WTF/Firestorm.wtf")
            let config = try String(contentsOf: configURL, encoding: .utf8)
            try expect(config.contains("eu.mnight.fstorm.eu"), "Firestorm portal set")
            try expect(config.contains("ruRU"), "Language set")
            try expect(config.contains("SET gxWindow \"1\""), "Unrelated setting retained")
            try expect(config.contains("# keep this comment"), "Comment retained")
            try expect(try Data(contentsOf: game.root.appendingPathComponent(".fsbuild")) == originalBuild, "Build metadata retained")
            try expect(try String(contentsOf: game.product.appendingPathComponent("WTF/Account/private/saved.txt"), encoding: .utf8) == "private account fixture", "Existing accounts untouched")

            let preparedAppInode = try fm.attributesOfItem(atPath: game.app.path)[.systemFileNumber] as? NSNumber
            try expect(preparedAppInode != nil, "Prepared app has a filesystem identifier")
            try write(config + "SET gxMaximize \"1\"\n", to: configURL)
            try core.prepare(game, locale: "ruRU", progress: { _ in })
            let appInodeAfterConfigRewrite = try fm.attributesOfItem(atPath: game.app.path)[.systemFileNumber] as? NSNumber
            try expect(appInodeAfterConfigRewrite == preparedAppInode, "Game-written settings do not replace the verified app on the next launch")
            try expect(try fm.contentsOfDirectory(atPath: backupRoot.path).sorted() == backupsBefore, "Updating settings preserves the original backup")
            try expect(try String(contentsOf: configURL, encoding: .utf8).contains("SET gxMaximize \"1\""), "Game-written settings are retained")
            try core.prepare(game, locale: "frFR", progress: { _ in })
            let appInodeAfterLanguageChange = try fm.attributesOfItem(atPath: game.app.path)[.systemFileNumber] as? NSNumber
            try expect(appInodeAfterLanguageChange == preparedAppInode, "Changing the language keeps the verified app in place")
            try expect(try String(contentsOf: configURL, encoding: .utf8).contains("SET textLocale \"frFR\""), "The new language is saved")

            try core.restoreLatest(game, progress: { _ in })
            try expect(try appFingerprint(game.app) == original, "Restore exact original app files")
            try expect(try String(contentsOf: configURL, encoding: .utf8) == fixture.originalConfig, "Restore exact original config")
            try expect(try !core.check(game).patched, "Restored client is no longer prepared")

            let absent = try Fixture(temporary.appendingPathComponent("AbsentConfig"))
            let absentGame = try GameInstallation.inspect(absent.root)
            let absentURL = absentGame.product.appendingPathComponent("WTF/Firestorm.wtf")
            try fm.removeItem(at: absentURL)
            let absentCore = LauncherCore(resources: absent.resources)
            try absentCore.prepare(absentGame, locale: "enUS", progress: { _ in })
            try absentCore.restoreLatest(absentGame, progress: { _ in })
            try expect(!fm.fileExists(atPath: absentURL.path), "Restore original absence of config")

            let bad = try Fixture(temporary.appendingPathComponent("BadPayload"))
            let badGame = try GameInstallation.inspect(bad.root)
            let badOriginal = try appFingerprint(badGame.app)
            let manifestURL = bad.resources.appendingPathComponent("client-manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
            var files = manifest["files"] as! [String: String]
            files["Contents/Info.plist"] = String(repeating: "0", count: 64)
            manifest["files"] = files
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            try expectThrows("Tampered payload") { try LauncherCore(resources: bad.resources).prepare(badGame, locale: "ruRU", progress: { _ in }) }
            try expect(try appFingerprint(badGame.app) == badOriginal, "Bad payload leaves original app intact")
            try expect(try String(contentsOf: badGame.product.appendingPathComponent("WTF/Firestorm.wtf"), encoding: .utf8) == bad.originalConfig, "Bad payload leaves config intact")

            let escaped = try Fixture(temporary.appendingPathComponent("EscapedBackup"))
            let escapedGame = try GameInstallation.inspect(escaped.root)
            let escapedOriginal = try appFingerprint(escapedGame.app)
            let outside = temporary.appendingPathComponent("OutsideBackup")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: escapedGame.root.appendingPathComponent(".firestorm-launcher-backups"), withDestinationURL: outside)
            try expectThrows("Backup symlink escapes installation") {
                try LauncherCore(resources: escaped.resources).prepare(escapedGame, locale: "ruRU", progress: { _ in })
            }
            try expect(try appFingerprint(escapedGame.app) == escapedOriginal, "Symlink rejection leaves app intact")
            try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Symlink rejection writes nothing outside installation")

            let escapedWTF = try Fixture(temporary.appendingPathComponent("EscapedWTF"))
            let escapedWTFGame = try GameInstallation.inspect(escapedWTF.root)
            let escapedWTFOriginal = try appFingerprint(escapedWTFGame.app)
            let wtfPath = escapedWTFGame.product.appendingPathComponent("WTF")
            let outsideWTF = temporary.appendingPathComponent("OutsideWTF")
            try fm.moveItem(at: wtfPath, to: outsideWTF)
            let originalExternalConfig = try Data(contentsOf: outsideWTF.appendingPathComponent("Firestorm.wtf"))
            try fm.createSymbolicLink(at: wtfPath, withDestinationURL: outsideWTF)
            try expectThrows("WTF symlink escapes installation") {
                try LauncherCore(resources: escapedWTF.resources).prepare(escapedWTFGame, locale: "ruRU", progress: { _ in })
            }
            try expect(try appFingerprint(escapedWTFGame.app) == escapedWTFOriginal, "WTF symlink rejection leaves app intact")
            try expect(try Data(contentsOf: outsideWTF.appendingPathComponent("Firestorm.wtf")) == originalExternalConfig, "WTF symlink rejection leaves external config intact")

            let cloneURL = temporary.appendingPathComponent("Independent Clone")
            let clone = try core.cloneInstall(from: game, to: cloneURL, locale: "enUS", progress: { _ in })
            try expect(try core.check(clone).patched, "Cloned client prepared")
            try expect(!fm.fileExists(atPath: clone.product.appendingPathComponent("WTF/Account").path), "Clone excludes account data")
            try write("changed only in clone", to: clone.root.appendingPathComponent("Data/data/data.000"))
            try expect(try String(contentsOf: game.root.appendingPathComponent("Data/data/data.000"), encoding: .utf8) == "archive fixture", "Clone Data is independent")
            try expectThrows("Destination already exists") { _ = try core.cloneInstall(from: game, to: cloneURL, locale: "ruRU", progress: { _ in }) }

            // The network installer supplies only CASC data and build metadata;
            // the native finalizer must add a validated app and fresh profile.
            let cleanRoot = temporary.appendingPathComponent("Clean Download")
            try fm.createDirectory(at: cleanRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: game.root.appendingPathComponent("Data"), to: cleanRoot.appendingPathComponent("Data"))
            try fm.copyItem(at: game.root.appendingPathComponent(".fsbuild"), to: cleanRoot.appendingPathComponent(".fsbuild"))
            let clean = try core.finishCleanInstall(in: cleanRoot, locale: "enUS", progress: { _ in })
            try expect(try core.check(clean).patched, "Clean downloaded Data can be finalized")
            try expect(try Data(contentsOf: clean.root.appendingPathComponent(".fsbuild")) == originalBuild, "Clean finalization retains downloaded build metadata")
            try expect(try String(contentsOf: clean.root.appendingPathComponent("Data/data/data.000"), encoding: .utf8) == "archive fixture", "Clean finalization retains downloaded Data")
            try expect(try String(contentsOf: clean.product.appendingPathComponent(".flavor.info"), encoding: .utf8) == "Product Flavor!STRING:0\nwow\n", "Clean finalization creates native product flavor")
            let cleanConfig = try Data(contentsOf: clean.product.appendingPathComponent("WTF/Firestorm.wtf"))
            try expect(String(decoding: cleanConfig, as: UTF8.self).contains("SET textLocale \"enUS\""), "Clean finalization sets selected language")
            let cleanFingerprint = try appFingerprint(clean.app)
            try expectThrows("Clean finalization cannot replace an existing app or config") {
                _ = try core.finishCleanInstall(in: clean.root, locale: "ruRU", progress: { _ in })
            }
            try expect(try appFingerprint(clean.app) == cleanFingerprint, "Repeated clean finalization leaves existing app intact")
            try expect(try Data(contentsOf: clean.product.appendingPathComponent("WTF/Firestorm.wtf")) == cleanConfig, "Repeated clean finalization leaves profile intact")

            // Force failure after the app and profile are installed. Downloaded
            // data must survive while only the finalizer's additions roll back.
            let failedRoot = temporary.appendingPathComponent("Invalid Download")
            try fm.createDirectory(at: failedRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: game.root.appendingPathComponent("Data"), to: failedRoot.appendingPathComponent("Data"))
            try write("invalid build metadata\n", to: failedRoot.appendingPathComponent(".fsbuild"))
            try expectThrows("Invalid downloaded metadata triggers finalization rollback") {
                _ = try core.finishCleanInstall(in: failedRoot, locale: "ruRU", progress: { _ in })
            }
            try expect(!fm.fileExists(atPath: failedRoot.appendingPathComponent("_midnight_/World of Warcraft.app").path), "Failed clean finalization removes its app")
            try expect(!fm.fileExists(atPath: failedRoot.appendingPathComponent("_midnight_/WTF/Firestorm.wtf").path), "Failed clean finalization removes its profile")
            try expect(!fm.fileExists(atPath: failedRoot.appendingPathComponent("_midnight_/.flavor.info").path), "Failed clean finalization removes its product flavor")
            try expect(try String(contentsOf: failedRoot.appendingPathComponent("Data/data/data.000"), encoding: .utf8) == "archive fixture", "Failed clean finalization preserves downloaded Data")
            try expect(try String(contentsOf: failedRoot.appendingPathComponent(".fsbuild"), encoding: .utf8) == "invalid build metadata\n", "Failed clean finalization preserves downloaded metadata")

            // Exercise the real child process so its relative Data lookup and
            // launch arguments cannot silently depend on the launcher's path.
            let launchFixture = try Fixture(temporary.appendingPathComponent("Launch Paths With Spaces"))
            let launchGame = try GameInstallation.inspect(launchFixture.root)
            let launchCore = LauncherCore(resources: launchFixture.resources)
            let launchExecutable = launchGame.app.appendingPathComponent("Contents/MacOS/World of Warcraft")
            try write("""
            #!/bin/sh
            printf 'CWD='
            /bin/pwd
            printf 'EXECUTABLE=%s\\n' "$0"
            printf 'ARG=%s\\n' "$@"
            printf 'BYPASS=%s\\n' "$FIRESTORM_BYPASS_LOG"
            printf 'DATA='
            /bin/cat ../Data/data/data.000
            printf '\\n'
            printf 'STDERR=child diagnostic\\n' >&2
            """ + "\n", to: launchExecutable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchExecutable.path)
            let launchLog = launchGame.logs.appendingPathComponent("GameLaunch.log")
            try write("previous launch diagnostic\n", to: launchLog)
            do {
                let previousInjection = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]
                defer {
                    if let previousInjection { setenv("DYLD_INSERT_LIBRARIES", previousInjection, 1) }
                    else { unsetenv("DYLD_INSERT_LIBRARIES") }
                }
                setenv("DYLD_INSERT_LIBRARIES", "/tmp/firestorm-unused-test-library.dylib", 1)
                let launched = try launchCore.launch(launchGame)
                launched.waitUntilExit()
                try expect(launched.terminationStatus == 0, "Game child exits successfully")
                try expect(launched.environment?["DYLD_INSERT_LIBRARIES"] == nil, "Game launch removes inherited library injection")
            }
            let launchOutput = try String(contentsOf: launchLog, encoding: .utf8)
            try expect(launchOutput.hasPrefix("previous launch diagnostic\n"), "Game launch appends to existing diagnostics")
            let workingDirectoryLine = launchOutput.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("CWD=") })
            let workingDirectory = workingDirectoryLine.map {
                URL(fileURLWithPath: String($0.dropFirst(4))).resolvingSymlinksInPath().path
            }
            try expect(workingDirectory == launchGame.product.resolvingSymlinksInPath().path, "Game starts in its product folder after resolving path aliases")
            try expect(launchOutput.contains("EXECUTABLE=\(launchExecutable.path)\n"), "Game runs from the selected app path")
            try expect(launchOutput.contains("ARG=-config\nARG=Firestorm.wtf\n"), "Game receives its connection-profile arguments")
            try expect(launchOutput.contains("BYPASS=\(launchGame.logs.appendingPathComponent("FirestormCertBypass.log").path)\n"), "Game patch log stays inside the selected installation")
            try expect(launchOutput.contains("DATA=archive fixture\n"), "Game can read Data through its relative parent path")
            try expect(launchOutput.contains("STDERR=child diagnostic\n"), "Game standard error is captured in launch diagnostics")
            try write("invalid executable format\n", to: launchExecutable)
            try expectThrows("Invalid game executable propagates launch failure") {
                _ = try launchCore.launch(launchGame)
            }

            let archive = game.root.appendingPathComponent("Data/data/data.000")
            try fm.removeItem(at: archive)
            try expectThrows("Missing primary archive") { _ = try GameInstallation.inspect(game.root) }
            try write("archive fixture", to: archive)
            let infoURL = game.app.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: nil) as! [String: Any]
            info["CFBundleVersion"] = "12.0.7.99999"
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            try expectThrows("Wrong build") { _ = try GameInstallation.inspect(game.root) }
            print("PASS: \(assertions) assertions. Install, restore, integrity, clone isolation, launch paths, and build validation verified.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
