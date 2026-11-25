import Foundation
import CryptoKit
import Darwin
import AppKit

struct LauncherFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let gameAppName = "World of Warcraft.app"
private let gameExecutableName = "World of Warcraft"
private let fm = FileManager.default

struct GameInstallation {
    static let supportedVersion = "12.0.7.68974"
    let root: URL
    let product: URL
    let app: URL
    let version: String
    var logs: URL { product.appendingPathComponent("Logs", isDirectory: true) }

    static func inspect(_ selection: URL) throws -> Self {
        guard selection.isFileURL else { throw LauncherFailure("Choose a local game folder.") }
        let selected = selection.standardizedFileURL
        let root: URL
        if selected.lastPathComponent == gameAppName {
            guard selected.deletingLastPathComponent().lastPathComponent == "_midnight_" else {
                throw LauncherFailure("The app must be inside _midnight_, next to the Data folder.")
            }
            root = selected.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        } else if selected.lastPathComponent == "_midnight_" {
            root = selected.deletingLastPathComponent().resolvingSymlinksInPath()
        } else {
            root = selected.resolvingSymlinksInPath()
        }
        let product = root.appendingPathComponent("_midnight_", isDirectory: true)
        let app = product.appendingPathComponent(gameAppName, isDirectory: true)
        try LauncherCore.ensureMutablePath(app, root: root)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        try LauncherCore.ensureMutablePath(infoURL, root: root)
        guard let info = try? PropertyListSerialization.propertyList(from: boundedRead(infoURL), format: nil) as? [String: Any],
              let version = info["CFBundleVersion"] as? String,
              info["CFBundleExecutable"] as? String == gameExecutableName else {
            throw LauncherFailure("No macOS World of Warcraft client was found in _midnight_.")
        }
        guard version == supportedVersion else {
            throw LauncherFailure("Found client \(version). Version \(supportedVersion) is required.")
        }
        let executable = app.appendingPathComponent("Contents/MacOS/\(gameExecutableName)")
        try LauncherCore.ensureMutablePath(executable, root: root)
        guard fm.isExecutableFile(atPath: executable.path), regularFile(executable) else {
            throw LauncherFailure("The game executable is missing or cannot be launched.")
        }
        let build = root.appendingPathComponent(".fsbuild")
        guard let data = try? boundedRead(build), let text = String(data: data, encoding: .utf8) else {
            throw LauncherFailure("The .fsbuild file is missing. Choose the Firestorm root folder containing Data and _midnight_.")
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first else { throw LauncherFailure("The .fsbuild file is empty.") }
        let names = header.components(separatedBy: "|").map { $0.components(separatedBy: "!")[0] }
        guard Set(names).count == names.count,
              let active = names.firstIndex(of: "Active"), let prod = names.firstIndex(of: "Product"),
              let ver = names.firstIndex(of: "Version"), let bkey = names.firstIndex(of: "Build Key"),
              let ckey = names.firstIndex(of: "CDN Key") else {
            throw LauncherFailure("The .fsbuild format is not recognized.")
        }
        let valid = lines.dropFirst().contains { row in
            let values = row.components(separatedBy: "|")
            guard values.count == names.count, values[active] == "1", values[prod] == "wow", values[ver] == version else { return false }
            return [values[bkey], values[ckey]].allSatisfy { key in
                guard key.utf8.count == 32, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
                let key = key.lowercased()
                return regularFile(root.appendingPathComponent("Data/config/\(key.prefix(2))/\(key.dropFirst(2).prefix(2))/\(key)"))
            }
        }
        guard valid else { throw LauncherFailure("The active \(version) build configuration or its Data/config files are missing.") }
        guard regularFile(root.appendingPathComponent("Data/data/data.000")) else {
            throw LauncherFailure("Game data Data/data/data.000 is missing. Choose a complete client.")
        }
        return Self(root: root, product: product, app: app, version: version)
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return attrs.isRegularFile == true && (attrs.fileSize ?? 0) > 0
    }

    private static func boundedRead(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw LauncherFailure("The metadata file is too large.") }
        return data
    }
}

struct ClientStatus {
    let patched: Bool
    let message: String
}

final class LauncherCore {
    struct Manifest: Codable {
        let version: String
        let files: [String: String]
    }
    private struct Backup: Codable {
        let id: String
        let date: Date
        let root: String
        let configExisted: Bool
        let stateExisted: Bool
        var restored: Bool
    }
    private struct InstallState: Codable {
        let version: String
        let backupID: String
        let installedAt: Date
    }

    let resources: URL
    init(resources: URL = Bundle.main.resourceURL!) { self.resources = resources }

    static func candidates() -> [URL] {
        let home = fm.homeDirectoryForCurrentUser
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent()
        var found = [
            adjacent.deletingLastPathComponent().appendingPathComponent("Firestorm-Game"),
            adjacent.appendingPathComponent("Firestorm-Game"),
            adjacent.appendingPathComponent("Firestorm Midnight"),
            adjacent.appendingPathComponent("Firestorm Midnight Client"),
            adjacent,
            home.appendingPathComponent("Games/Firestorm Midnight"),
            home.appendingPathComponent("Games/Firestorm Midnight Client")
        ]
        if let paths = Bundle.main.object(forInfoDictionaryKey: "SuggestedClientPaths") as? [String] {
            found.append(contentsOf: paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted && fm.fileExists(atPath: $0.path) }
    }

    static func gameIsRunning() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            !app.isTerminated && (app.executableURL?.lastPathComponent == gameExecutableName || app.bundleURL?.lastPathComponent == gameAppName)
        }) { return true }
        guard let result = try? run("/usr/bin/pgrep", ["-f", "/Contents/MacOS/World of Warcraft"], allowFailure: true) else { return false }
        return result.status == 0
    }

    func check(_ game: GameInstallation) throws -> ClientStatus {
        _ = try GameInstallation.inspect(game.root)
        let manifest = try readManifest()
        if CASCStorage.needsIndexUpgrade(in: game.root.appendingPathComponent("Data/data",isDirectory:true)) {
            return ClientStatus(patched:false,message:"The starter Data indices need repair. Close the game and click Repair client; downloaded archives will be preserved.")
        }
        do {
            try verifyFiles(game.app, manifest: manifest)
            _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", game.app.path])
            guard configurationReady(game.product.appendingPathComponent("WTF/Firestorm.wtf")) else {
                return ClientStatus(patched: false, message: "The patch is installed. The Firestorm connection profile needs preparation.")
            }
            return ClientStatus(patched: true, message: "Client \(game.version) verified. The patch is installed.")
        } catch {
            return ClientStatus(patched: false, message: "Client \(game.version) found. Firestorm files need preparation.")
        }
    }

    func launch(_ game: GameInstallation) throws -> Process {
        _ = try GameInstallation.inspect(game.root)
        try requireStopped()
        let outputURL = game.logs.appendingPathComponent("GameLaunch.log")
        try Self.ensureMutablePath(outputURL, root: game.root)
        try fm.createDirectory(at: game.logs, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: outputURL.path) {
            guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LauncherFailure("Could not create the game launch log.")
            }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try output.seekToEnd()
        let executable = game.app.appendingPathComponent("Contents/MacOS/\(gameExecutableName)")
        let header = "\n\(Date().ISO8601Format()) Starting \(executable.path)\nWorking directory: \(game.product.path)\n"
        try output.write(contentsOf: Data(header.utf8))
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment["FIRESTORM_BYPASS_LOG"] = game.logs.appendingPathComponent("FirestormCertBypass.log").path
        let process = Process()
        process.executableURL = executable
        // WoW resolves its CAS data relative to the installed product directory.
        // Launch the executable in place so App Translocation cannot separate it
        // from the validated .fsbuild and Data directory.
        process.currentDirectoryURL = game.product
        process.arguments = ["-config", "Firestorm.wtf"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    func prepare(_ game: GameInstallation, locale: String, progress: (String) -> Void) throws {
        try validateLocale(locale)
        _ = try GameInstallation.inspect(game.root)
        let lock = try acquireLock(game.root)
        defer { Self.releaseLock(lock) }
        try requireStopped()
        try validateMutableLayout(game)
        let storage = game.root.appendingPathComponent("Data/data",isDirectory:true)
        if CASCStorage.needsIndexUpgrade(in:storage) {
            progress("Repairing local Data indices. Downloaded game archives will be preserved…")
            try CASCStorage.rebuildIndices(in:storage)
        }
        let config = game.product.appendingPathComponent("WTF/Firestorm.wtf")
        let previous = fm.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        let next = try mergedConfiguration(previous, locale: locale)
        let manifest = try readManifest()
        if (try? verifyFiles(game.app, manifest: manifest)) != nil,
           (try? Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", game.app.path])) != nil {
            if previous == next {
                progress("Files and settings are already ready.")
            } else {
                // WoW can rewrite its profile when it exits. Keep the verified app in place.
                try requireStopped()
                try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
                try next.write(to: config, options: .atomic)
                progress("Game settings updated.")
            }
            return
        }
        progress("Verifying the bundled client…")
        let stage = game.root.appendingPathComponent(".firestorm-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let prepared = try extractPayload(to: stage)
        try requireStopped()
        progress("Saving a backup…")
        let backup = try makeBackup(game)
        let oldApp = stage.appendingPathComponent("Original.app", isDirectory: true)
        var movedOriginal = false
        var installed = false
        do {
            try requireStopped()
            try fm.moveItem(at: game.app, to: oldApp)
            movedOriginal = true
            try fm.moveItem(at: prepared, to: game.app)
            installed = true
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try next.write(to: config, options: .atomic)
            let state = InstallState(version: game.version, backupID: backup.id, installedAt: Date())
            try JSONEncoder().encode(state).write(to: stateURL(game.root), options: .atomic)
            _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", game.app.path])
            progress("Patch installed. Connection settings are ready.")
        } catch {
            var rollbackErrors: [String] = []
            if installed { do { try fm.removeItem(at: game.app) } catch { rollbackErrors.append("removing the new copy") } }
            if movedOriginal { do { try fm.moveItem(at: oldApp, to: game.app) } catch { rollbackErrors.append("restoring the app") } }
            do { try restoreConfiguration(backup, game: game) } catch { rollbackErrors.append("restoring settings") }
            if !rollbackErrors.isEmpty {
                throw LauncherFailure("Operation failed: \(error.localizedDescription). Rollback could not finish: \(rollbackErrors.joined(separator: ", ")). Backup: \(backupDirectory(game.root, backup.id).path)")
            }
            throw error
        }
    }

    func cloneInstall(from game: GameInstallation, to destination: URL, locale: String, progress: (String) -> Void) throws -> GameInstallation {
        try validateLocale(locale)
        _ = try GameInstallation.inspect(game.root)
        let sourceLock = try acquireLock(game.root)
        defer { Self.releaseLock(sourceLock) }
        try requireStopped()
        let originalTarget = destination.standardizedFileURL
        let parent = originalTarget.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(originalTarget.lastPathComponent, isDirectory: true)
        guard target.isFileURL, target.lastPathComponent != ".", target.lastPathComponent != "..",
              fm.fileExists(atPath: parent.path), !fm.fileExists(atPath: target.path),
              !target.path.hasPrefix(game.root.path + "/") else {
            throw LauncherFailure("Choose a new folder that does not exist yet, outside the original client.")
        }
        let stage = parent.appendingPathComponent(".firestorm-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        progress("Creating an independent APFS copy of the game archives…")
        let dataSource = game.root.appendingPathComponent("Data").resolvingSymlinksInPath()
        if let files = fm.enumerator(at: dataSource, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw LauncherFailure("A symbolic link was found inside Data. An independent copy requires regular game files.")
                }
            }
        } else { throw LauncherFailure("Could not read the Data folder.") }
        let dataTarget = stage.appendingPathComponent("Data")
        let copyResult = try Self.run("/bin/cp", ["-cR", dataSource.path, dataTarget.path], allowFailure: true)
        guard copyResult.status == 0 else {
            throw LauncherFailure("Could not create an APFS copy. The source client and destination must be on the same APFS volume. You can select an existing client instead. \(copyResult.output.prefix(400))")
        }
        try fm.copyItem(at: game.root.appendingPathComponent(".fsbuild"), to: stage.appendingPathComponent(".fsbuild"))
        let product = stage.appendingPathComponent("_midnight_", isDirectory: true)
        try fm.createDirectory(at: product, withIntermediateDirectories: true)
        let flavor = game.product.appendingPathComponent(".flavor.info")
        if fm.fileExists(atPath: flavor.path) { try fm.copyItem(at: flavor, to: product.appendingPathComponent(".flavor.info")) }
        progress("Installing the client and patch…")
        let payloadStage = stage.appendingPathComponent(".payload", isDirectory: true)
        try fm.createDirectory(at: payloadStage, withIntermediateDirectories: false)
        let payload = try extractPayload(to: payloadStage)
        try fm.moveItem(at: payload, to: product.appendingPathComponent(gameAppName))
        try fm.removeItem(at: payloadStage)
        let wtf = product.appendingPathComponent("WTF", isDirectory: true)
        try fm.createDirectory(at: wtf, withIntermediateDirectories: false)
        try mergedConfiguration(nil, locale: locale).write(to: wtf.appendingPathComponent("Firestorm.wtf"), options: .atomic)
        _ = try GameInstallation.inspect(stage)
        try requireStopped()
        guard !fm.fileExists(atPath: target.path) else { throw LauncherFailure("The destination folder already exists. Choose another folder.") }
        try fm.moveItem(at: stage, to: target)
        progress("The independent client is ready.")
        return try GameInstallation.inspect(target)
    }

    /// Completes a caller-owned clean staging folder after its downloader has
    /// supplied .fsbuild and Data. Existing client apps or settings are never
    /// replaced here; callers publish the entire staging folder atomically.
    func finishCleanInstall(in root: URL, locale: String, progress: (String) -> Void) throws -> GameInstallation {
        try validateLocale(locale)
        guard root.isFileURL else { throw LauncherFailure("Choose a local installation folder.") }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let attrs = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard attrs.isDirectory == true else { throw LauncherFailure("The clean installation staging folder is missing.") }
        let lock = try acquireLock(root)
        defer { Self.releaseLock(lock) }
        try requireStopped()

        let product = root.appendingPathComponent("_midnight_", isDirectory: true)
        let app = product.appendingPathComponent(gameAppName, isDirectory: true)
        let wtf = product.appendingPathComponent("WTF", isDirectory: true)
        let config = wtf.appendingPathComponent("Firestorm.wtf")
        let flavor = product.appendingPathComponent(".flavor.info")
        let metadata = root.appendingPathComponent(".fsbuild")
        let primaryArchive = root.appendingPathComponent("Data/data/data.000")
        for path in [app, config, flavor, metadata, primaryArchive] { try Self.ensureMutablePath(path, root: root) }
        guard fm.fileExists(atPath: metadata.path), fm.fileExists(atPath: primaryArchive.path) else {
            throw LauncherFailure("The clean download has not supplied .fsbuild and Data/data/data.000 yet.")
        }
        guard !fm.fileExists(atPath: app.path), !fm.fileExists(atPath: config.path) else {
            throw LauncherFailure("The clean staging folder already contains a client or game settings.")
        }
        let flavorData = Data("Product Flavor!STRING:0\nwow\n".utf8)
        let flavorExisted = fm.fileExists(atPath: flavor.path)
        if flavorExisted, try Data(contentsOf: flavor) != flavorData {
            throw LauncherFailure("The clean staging folder contains an unexpected product flavor.")
        }
        let productExisted = fm.fileExists(atPath: product.path)
        let wtfExisted = fm.fileExists(atPath: wtf.path)
        let payloadStage = root.appendingPathComponent(".firestorm-payload-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: payloadStage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: payloadStage) }
        progress("Verifying the bundled client…")
        let prepared = try extractPayload(to: payloadStage)
        var installedApp = false
        var installedConfig = false
        var installedFlavor = false
        do {
            try requireStopped()
            guard !fm.fileExists(atPath: app.path), !fm.fileExists(atPath: config.path) else {
                throw LauncherFailure("The clean staging folder changed during installation.")
            }
            progress("Installing the client, patch and connection profile…")
            try fm.createDirectory(at: product, withIntermediateDirectories: true)
            try fm.moveItem(at: prepared, to: app)
            installedApp = true
            try fm.createDirectory(at: wtf, withIntermediateDirectories: true)
            try mergedConfiguration(nil, locale: locale).write(to: config, options: .atomic)
            installedConfig = true
            if !flavorExisted {
                try flavorData.write(to: flavor, options: .atomic)
                installedFlavor = true
            }
            let game = try GameInstallation.inspect(root)
            progress("The clean client installation is ready.")
            return game
        } catch {
            if installedApp { try? fm.removeItem(at: app) }
            if installedConfig { try? fm.removeItem(at: config) }
            if installedFlavor { try? fm.removeItem(at: flavor) }
            if !wtfExisted, (try? fm.contentsOfDirectory(atPath: wtf.path).isEmpty) == true { try? fm.removeItem(at: wtf) }
            if !productExisted, (try? fm.contentsOfDirectory(atPath: product.path).isEmpty) == true { try? fm.removeItem(at: product) }
            throw error
        }
    }

    func restoreLatest(_ game: GameInstallation, progress: (String) -> Void) throws {
        _ = try GameInstallation.inspect(game.root)
        let lock = try acquireLock(game.root)
        defer { Self.releaseLock(lock) }
        try requireStopped()
        try validateMutableLayout(game)
        let backupRoot = game.root.appendingPathComponent(".firestorm-launcher-backups", isDirectory: true)
        let folders = (try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
        let backups = folders.compactMap { url -> Backup? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
                  let record = try? JSONDecoder().decode(Backup.self, from: data),
                  record.id == url.lastPathComponent, record.root == game.root.path, !record.restored else { return nil }
            return record
        }.sorted { $0.date > $1.date }
        guard var backup = backups.first else { throw LauncherFailure("This launcher has not created any backups yet.") }
        let directory = backupDirectory(game.root, backup.id)
        try Self.ensureMutablePath(directory, root: game.root)
        let savedApp = directory.appendingPathComponent(gameAppName)
        guard fm.fileExists(atPath: savedApp.path) else { throw LauncherFailure("The app is missing from the backup.") }
        let stage = game.root.appendingPathComponent(".firestorm-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        progress("Restoring the backup…")
        let restoredApp = stage.appendingPathComponent(gameAppName)
        try copyBundle(savedApp, restoredApp)
        let config = game.product.appendingPathComponent("WTF/Firestorm.wtf")
        let currentConfig = fm.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        let currentState = fm.fileExists(atPath: stateURL(game.root).path) ? try Data(contentsOf: stateURL(game.root)) : nil
        let oldApp = stage.appendingPathComponent("Current.app")
        var originalMoved = false
        var replacementInstalled = false
        do {
            try requireStopped()
            try fm.moveItem(at: game.app, to: oldApp)
            originalMoved = true
            try fm.moveItem(at: restoredApp, to: game.app)
            replacementInstalled = true
            try restoreConfiguration(backup, game: game)
            backup.restored = true
            try JSONEncoder().encode(backup).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
            progress("The original app and settings have been restored.")
        } catch {
            var rollbackErrors: [String] = []
            if replacementInstalled { do { try fm.removeItem(at: game.app) } catch { rollbackErrors.append("removing the restored app") } }
            if originalMoved { do { try fm.moveItem(at: oldApp, to: game.app) } catch { rollbackErrors.append("restoring the current app") } }
            do { try writeOrRemove(currentConfig, at: config); try writeOrRemove(currentState, at: stateURL(game.root)) } catch { rollbackErrors.append("restoring the current settings") }
            if !rollbackErrors.isEmpty { throw LauncherFailure("Restore and rollback could not finish: \(rollbackErrors.joined(separator: ", ")). Backup: \(directory.path)") }
            throw error
        }
    }

    private func makeBackup(_ game: GameInstallation) throws -> Backup {
        let id = UUID().uuidString
        let directory = backupDirectory(game.root, id)
        try Self.ensureMutablePath(directory, root: game.root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try copyBundle(game.app, directory.appendingPathComponent(gameAppName))
            let config = game.product.appendingPathComponent("WTF/Firestorm.wtf")
            let configExisted = fm.fileExists(atPath: config.path)
            if configExisted { try fm.copyItem(at: config, to: directory.appendingPathComponent("Firestorm.wtf")) }
            let stateExisted = fm.fileExists(atPath: stateURL(game.root).path)
            if stateExisted { try fm.copyItem(at: stateURL(game.root), to: directory.appendingPathComponent("state.json")) }
            let backup = Backup(id: id, date: Date(), root: game.root.path, configExisted: configExisted, stateExisted: stateExisted, restored: false)
            try JSONEncoder().encode(backup).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
            return backup
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func restoreConfiguration(_ backup: Backup, game: GameInstallation) throws {
        let directory = backupDirectory(game.root, backup.id)
        let config = game.product.appendingPathComponent("WTF/Firestorm.wtf")
        let configData = backup.configExisted ? try Data(contentsOf: directory.appendingPathComponent("Firestorm.wtf")) : nil
        let stateData = backup.stateExisted ? try Data(contentsOf: directory.appendingPathComponent("state.json")) : nil
        try writeOrRemove(configData, at: config)
        try writeOrRemove(stateData, at: stateURL(game.root))
    }

    private func writeOrRemove(_ data: Data?, at url: URL) throws {
        if let data {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    private func extractPayload(to directory: URL) throws -> URL {
        let manifest = try readManifest()
        let archive = resources.appendingPathComponent("Client.zip")
        guard fm.fileExists(atPath: archive.path) else { throw LauncherFailure("The bundled client archive Client.zip is missing.") }
        try validateArchive(archive)
        _ = try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let app = directory.appendingPathComponent(gameAppName)
        try verifyFiles(app, manifest: manifest)
        guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any],
              info["CFBundleVersion"] as? String == GameInstallation.supportedVersion else { throw LauncherFailure("The bundled client version does not match the supported version.") }
        _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func readManifest() throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("client-manifest.json")))
        guard manifest.version == GameInstallation.supportedVersion, !manifest.files.isEmpty,
              manifest.files.keys.contains("Contents/Info.plist"),
              manifest.files.keys.contains("Contents/MacOS/\(gameExecutableName)"),
              manifest.files.allSatisfy({ key, value in
                  !key.hasPrefix("/") && !key.split(separator: "/").contains("..") &&
                  value.utf8.count == 64 && value.allSatisfy({ $0.isASCII && $0.isHexDigit })
              }) else { throw LauncherFailure("The bundled client checksum manifest is invalid.") }
        return manifest
    }

    // Check the central directory before extraction so even a corrupted archive
    // cannot write outside its private staging folder or create symbolic links.
    private func validateArchive(_ archive: URL) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        func fail() -> LauncherFailure { LauncherFailure("The bundled client archive is invalid or unsafe.") }
        func u16(_ at: Int) throws -> UInt16 {
            guard at >= 0, at + 2 <= data.count else { throw fail() }
            return UInt16(data[at]) | UInt16(data[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= data.count else { throw fail() }
            return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        }
        guard data.count >= 22 else { throw fail() }
        var eocd: Int?
        for at in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(at) == 0x06054b50, at + 22 + Int(try u16(at + 20)) == data.count { eocd = at; break }
        }
        guard let end = eocd, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw fail() }
        let count = Int(try u16(end + 10))
        guard count > 0, count < 65_535, try u16(end + 8) == UInt16(count) else { throw fail() }
        let centralStart = Int(try u32(end + 16))
        let centralSize = Int(try u32(end + 12))
        guard centralStart >= 0, centralStart + centralSize == end else { throw fail() }
        var cursor = centralStart
        var names = Set<String>()
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw fail() }
            let nameLength = Int(try u16(cursor + 28))
            let extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32))
            let mode = (try u32(cursor + 38)) >> 16
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0,
                  let name = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                  !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(".."),
                  name == gameAppName + "/" || name.hasPrefix(gameAppName + "/"),
                  mode & 0o170000 != 0o120000, names.insert(name).inserted else { throw fail() }
            cursor = next
        }
        guard cursor == end else { throw fail() }
    }

    private func verifyFiles(_ app: URL, manifest: Manifest) throws {
        guard let enumerator = fm.enumerator(atPath: app.path) else {
            throw LauncherFailure("Could not verify the client files.")
        }
        var actual = Set<String>()
        for case let key as String in enumerator {
            let file = app.appendingPathComponent(key)
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard attrs.isSymbolicLink != true else { throw LauncherFailure("Symbolic links inside the bundled client are not supported.") }
            if attrs.isRegularFile == true {
                guard let expected = manifest.files[key], try Self.sha256(file) == expected.lowercased() else {
                    throw LauncherFailure("Checksum mismatch: \(file.lastPathComponent).")
                }
                actual.insert(key)
            } else if attrs.isDirectory != true {
                throw LauncherFailure("An unsupported file type was found in the bundled client.")
            }
        }
        guard actual == Set(manifest.files.keys) else { throw LauncherFailure("The bundled client is incomplete.") }
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func mergedConfiguration(_ data: Data?, locale: String) throws -> Data {
        var text = ""
        if let data {
            guard let decoded = String(data: data, encoding: .utf8) else { throw LauncherFailure("Firestorm.wtf must use UTF-8 encoding.") }
            text = decoded
        }
        let settings = ["portal": "eu.mnight.fstorm.eu", "textlocale": locale, "audiolocale": locale]
        let expression = try NSRegularExpression(pattern: "^\\s*SET\\s+([^\\s]+)\\s+.*$", options: [.caseInsensitive])
        var lines = text.components(separatedBy: .newlines).filter { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range), let keyRange = Range(match.range(at: 1), in: line) else { return true }
            return settings[String(line[keyRange]).lowercased()] == nil
        }
        while lines.last == "" { lines.removeLast() }
        lines += ["SET portal \"eu.mnight.fstorm.eu\"", "SET textLocale \"\(locale)\"", "SET audioLocale \"\(locale)\""]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func configurationReady(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: "^\\s*SET\\s+(portal|textLocale|audioLocale)\\s+\"([^\"]*)\"\\s*$", options: [.caseInsensitive, .anchorsMatchLines]) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var values: [String: String] = [:]
        for match in expression.matches(in: text, range: range) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else { return false }
            values[String(text[key]).lowercased()] = String(text[value])
        }
        guard values["portal"] == "eu.mnight.fstorm.eu", let textLocale = values["textlocale"], values["audiolocale"] == textLocale else { return false }
        return (try? validateLocale(textLocale)) != nil
    }

    private func validateLocale(_ locale: String) throws {
        guard ["ruRU", "enUS", "enGB", "deDE", "frFR", "esES", "esMX", "itIT", "ptBR", "koKR", "zhCN", "zhTW"].contains(locale) else {
            throw LauncherFailure("The selected game language is not supported.")
        }
    }

    private func validateMutableLayout(_ game: GameInstallation) throws {
        for path in [game.app, game.product.appendingPathComponent("WTF/Firestorm.wtf"), game.root.appendingPathComponent(".firestorm-launcher-backups"), stateURL(game.root)] {
            try Self.ensureMutablePath(path, root: game.root)
        }
        for path in [game.product.appendingPathComponent("WTF/Firestorm.wtf"), stateURL(game.root)] {
            if let attrs = try? fm.attributesOfItem(atPath: path.path), attrs[.type] as? FileAttributeType != .typeRegular {
                throw LauncherFailure("The path \(path.lastPathComponent) is not a regular file. Fix it before preparing the client.")
            }
        }
        let backups = game.root.appendingPathComponent(".firestorm-launcher-backups")
        if let attrs = try? fm.attributesOfItem(atPath: backups.path), attrs[.type] as? FileAttributeType != .typeDirectory {
            throw LauncherFailure("The backup folder path is occupied by a file.")
        }
    }

    static func ensureMutablePath(_ url: URL, root: URL) throws {
        let base = root.standardizedFileURL
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(base.path + "/") else { throw LauncherFailure("The write path is outside the client folder.") }
        let relative = path.path.dropFirst(base.path.count + 1)
        var cursor = base
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if let attrs = try? fm.attributesOfItem(atPath: cursor.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw LauncherFailure("Installation requires regular folders without symbolic links: \(cursor.lastPathComponent).")
            }
        }
    }

    private func requireStopped() throws {
        guard !Self.gameIsRunning() else { throw LauncherFailure("Close all running copies of World of Warcraft first.") }
    }
    private func stateURL(_ root: URL) -> URL { root.appendingPathComponent(".firestorm-launcher-state.json") }
    private func backupDirectory(_ root: URL, _ id: String) -> URL { root.appendingPathComponent(".firestorm-launcher-backups/\(id)", isDirectory: true) }
    private func copyBundle(_ source: URL, _ destination: URL) throws {
        _ = try Self.run("/usr/bin/ditto", ["--rsrc", "--extattr", source.path, destination.path])
    }

    private func acquireLock(_ root: URL) throws -> Int32 {
        // Locks live outside the installation so cloning can read an original
        // client without changing a single source file or requiring write access.
        let directory = fm.temporaryDirectory.appendingPathComponent("firestorm-launcher-locks", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try fm.attributesOfItem(atPath: directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw LauncherFailure("Could not access a secure installation lock folder.")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(key + ".lock")
        let descriptor = Darwin.open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LauncherFailure("Could not create an installation lock.") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == getuid(), status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw LauncherFailure("The installation lock file is unsafe.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw LauncherFailure("Another launcher is already using this installation.")
        }
        return descriptor
    }
    private static func releaseLock(_ descriptor: Int32) { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }

    struct CommandResult { let status: Int32; let output: String }
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> CommandResult {
        let outputURL = fm.temporaryDirectory.appendingPathComponent("firestorm-process-\(UUID().uuidString).log")
        guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LauncherFailure("Could not create a temporary operation log.")
        }
        defer { try? fm.removeItem(at: outputURL) }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 131_072) ?? Data()
        let output = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CommandResult(status: process.terminationStatus, output: output)
        guard allowFailure || process.terminationStatus == 0 else {
            throw LauncherFailure("The \(URL(fileURLWithPath: executable).lastPathComponent) operation failed with code \(process.terminationStatus). \(output.prefix(900))")
        }
        return result
    }
}
