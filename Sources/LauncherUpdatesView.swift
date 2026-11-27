import AppKit

/// Launcher updates have their own progress and explicit restart action, so a
/// background check or download never interrupts installing or playing WoW.
@MainActor
final class LauncherUpdatesView: NSView {
    private enum Notice {
        case current
        case checkFailed(Error)
        case downloadFailed(Error)
        case installFailed(Error)
        case message(String)
    }
    private let service: LauncherUpdateService
    private let currentVersion: String
    private let heading = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let action = NSButton()
    private let releaseNotes = NSButton()
    private let secondary = NSButton()
    private var release: LauncherUpdateRelease?
    private var checkRequest: URLSessionDataTask?
    private var downloadRequest: URLSessionDownloadTask?
    private var generation = UUID()
    private var checking = false
    private var manualCheck = false
    private var downloading = false
    private var downloadProgress = 0.0
    private var archiveURL: URL?
    private var downloadDirectory: URL?
    private var notice: Notice?
    private var noticeIsError = false
    private var lastCheckAt = Date.distantPast
    private var checkTimer: Timer?

    private(set) var isPreparing = false
    private(set) var replacementStarted = false
    var downloadUnavailableReason: (() -> String?)?
    var installationUnavailableReason: (() -> String?)?
    var preparationChanged: (() -> Void)?

    init(service: LauncherUpdateService = LauncherUpdateService(),
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.service = service
        self.currentVersion = currentVersion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.19, alpha: 1).cgColor
        layer?.cornerRadius = 10
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3
        message.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(performUpdateAction)
        releaseNotes.bezelStyle = .rounded
        releaseNotes.target = self
        releaseNotes.action = #selector(openReleaseNotes)
        secondary.bezelStyle = .rounded
        secondary.target = self
        secondary.action = #selector(cancelOrDismiss)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, spinner])
        header.alignment = .centerY
        let buttons = NSStackView(views: [action, releaseNotes, secondary])
        buttons.spacing = 8
        buttons.detachesHiddenViews = true
        let stack = NSStackView(views: [header, message, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        checkTimer?.invalidate()
        checkRequest?.cancel()
        downloadRequest?.cancel()
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
    }

    func startAutomaticChecks() {
        guard checkTimer == nil else { return }
        checkForUpdates(manual: false)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true,
                      Date().timeIntervalSince(self.lastCheckAt) >= 6 * 60 * 60 else { return }
                self.checkForUpdates(manual: false)
            }
        }
    }

    func refreshLocalization() { render() }

    func checkForUpdates(manual: Bool = true) {
        guard !checking, !downloading, !isPreparing, archiveURL == nil else {
            if manual { reveal() }
            return
        }
        generation = UUID()
        let requestedGeneration = generation
        checking = true
        manualCheck = manual
        notice = nil
        noticeIsError = false
        lastCheckAt = Date()
        render()
        if manual { reveal() }
        checkRequest = service.check(currentVersion: currentVersion) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.checkRequest = nil
                self.checking = false
                switch result {
                case .success(let release):
                    self.release = release
                    if manual && release == nil {
                        self.notice = .current
                    }
                case .failure(let error):
                    if manual {
                        self.notice = .checkFailed(error)
                        self.noticeIsError = true
                    }
                }
                self.render()
            }
        }
    }

    private func reveal() {
        guard !isHidden else { return }
        superview?.layoutSubtreeIfNeeded()
        scrollToVisible(bounds)
    }

    private func render() {
        isHidden = release == nil && notice == nil && !(checking && manualCheck)
        heading.stringValue = release.map { LF("Firestorm Launcher %@ is available", $0.version.description) } ?? L("Launcher updates")
        if let notice {
            switch notice {
            case .current:
                message.stringValue = LF("You’re up to date. Firestorm Launcher %@ is installed.", currentVersion)
            case .checkFailed(let error):
                message.stringValue = LF("Could not check for launcher updates. %@", error.localizedDescription)
            case .downloadFailed(let error):
                message.stringValue = LF("Could not download the launcher update. %@", error.localizedDescription)
            case .installFailed(let error):
                message.stringValue = LF("Could not install the launcher update. %@", error.localizedDescription)
            case .message(let text):
                message.stringValue = L(text)
            }
        } else if isPreparing {
            message.stringValue = L("Preparing the update. The launcher will restart when it’s ready…")
        } else if downloading {
            message.stringValue = LF("Downloading launcher update… %d%%", Int(downloadProgress * 100))
        } else if archiveURL != nil {
            message.stringValue = L("Update downloaded and verified. Close WoW, then install and restart the launcher.")
        } else if checking {
            message.stringValue = L("Checking for launcher updates…")
        } else {
            message.stringValue = L("Download the latest launcher from GitHub. Your game files and settings stay in place.")
        }
        message.textColor = noticeIsError ? .systemOrange : .secondaryLabelColor
        if checking || isPreparing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        progress.isHidden = !downloading
        progress.doubleValue = downloadProgress
        progress.setAccessibilityLabel(L("Launcher update download progress"))
        action.title = archiveURL == nil ? L("Download update") : L("Install and restart")
        action.isHidden = release == nil || downloading || isPreparing || checking
        releaseNotes.title = L("Release notes ↗")
        releaseNotes.isHidden = release == nil && !noticeIsError
        releaseNotes.isEnabled = !isPreparing
        secondary.title = checking || downloading ? L("Cancel") : L("Dismiss")
        secondary.isHidden = isPreparing || (!checking && !downloading && notice == nil)
    }

    @objc private func performUpdateAction() {
        guard !checking, !downloading, !isPreparing, let release else { return }
        if let archiveURL { install(release, archiveURL: archiveURL) }
        else { download(release) }
    }

    private func download(_ release: LauncherUpdateRelease) {
        if let reason = downloadUnavailableReason?() { showError(reason); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firestorm-launcher-update-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { showError(error.localizedDescription); return }
        cleanupDownload()
        downloadDirectory = directory
        generation = UUID()
        let requestedGeneration = generation
        downloading = true
        downloadProgress = 0
        notice = nil
        noticeIsError = false
        render()
        downloadRequest = service.download(release: release, to: directory.appendingPathComponent("update.zip"), progress: { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.downloadProgress = min(1, max(0, fraction))
                self.render()
            }
        }, completion: { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.downloadRequest = nil
                self.downloading = false
                switch result {
                case .success(let url): self.archiveURL = url
                case .failure(let error):
                    self.cleanupDownload()
                    self.notice = .downloadFailed(error)
                    self.noticeIsError = true
                }
                self.render()
            }
        })
    }

    private func install(_ release: LauncherUpdateRelease, archiveURL: URL) {
        if let reason = installationUnavailableReason?() { showError(reason); return }
        guard Bundle.main.bundleIdentifier == "local.firestorm.launcher" else {
            showError("Install updates from the regular Firestorm Launcher app.")
            return
        }
        isPreparing = true
        notice = nil
        noticeIsError = false
        render()
        preparationChanged?()
        let expectedVersion = release.version.description
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try LauncherUpdateInstaller.prepare(archiveURL: archiveURL, expectedVersion: expectedVersion) }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case .success(let prepared) = result { prepared.discard() }
                    return
                }
                do {
                    let prepared = try result.get()
                    if let reason = self.installationUnavailableReason?() {
                        prepared.discard()
                        throw NSError(domain: "LauncherUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: L(reason)])
                    }
                    do { try prepared.startReplacement() }
                    catch { prepared.discard(); throw error }
                    self.replacementStarted = true
                    self.cleanupDownload()
                    NSApp.terminate(nil)
                } catch {
                    self.isPreparing = false
                    self.preparationChanged?()
                    self.notice = .installFailed(error)
                    self.noticeIsError = true
                    self.render()
                    self.reveal()
                }
            }
        }
    }

    private func showError(_ text: String) {
        notice = .message(text)
        noticeIsError = true
        render()
        reveal()
    }

    private func cleanupDownload() {
        archiveURL = nil
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
        downloadDirectory = nil
    }

    @objc private func cancelOrDismiss() {
        if checking || downloading {
            generation = UUID()
            checkRequest?.cancel()
            checkRequest = nil
            downloadRequest?.cancel()
            downloadRequest = nil
            checking = false
            downloading = false
            cleanupDownload()
        }
        notice = nil
        noticeIsError = false
        render()
    }

    @objc private func openReleaseNotes() {
        NSWorkspace.shared.open(release?.releaseURL ?? LauncherUpdateService.releasesURL)
    }
}
