import AppKit
import Network

private let amber = NSColor(calibratedRed: 1, green: 0.66, blue: 0.27, alpha: 1)
private let muted = NSColor(calibratedRed: 0.58, green: 0.63, blue: 0.71, alpha: 1)

final class Surface: NSView {
    init(_ color: NSColor, radius: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class HeroView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.28, alpha: 1),
                            NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1)])?.draw(in: bounds, angle: 25)
        let w = bounds.width, h = bounds.height
        for i in 0..<8 {
            let r = CGFloat(36 + i * 19)
            NSColor(calibratedRed: 0.98, green: 0.51, blue: 0.17, alpha: 0.018).setFill()
            NSBezierPath(ovalIn: NSRect(x: w - 132 - r, y: h * 0.53 - r, width: r * 2, height: r * 2)).fill()
        }
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: w * 0.44, y: 0))
        for p in [NSPoint(x:w*0.62,y:h*0.43),NSPoint(x:w*0.69,y:h*0.3),NSPoint(x:w*0.78,y:h*0.7),NSPoint(x:w*0.92,y:h*0.19),NSPoint(x:w,y:h*0.36),NSPoint(x:w,y:0)] { mountain.line(to:p) }
        mountain.close()
        NSColor(calibratedRed:0.06,green:0.075,blue:0.12,alpha:0.9).setFill()
        mountain.fill()
        let mark = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)
        mark?.isTemplate = false
        if let mark {
            let rect = NSRect(x:w-178,y:52,width:88,height:113)
            mark.draw(in:rect,from:.zero,operation:.sourceOver,fraction:0.24)
        }
    }
}

private final class LauncherScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var selected: GameInstallation?
    private let core = LauncherCore()
    private var busy = false
    private var game: NSRunningApplication?
    private var gameProcess: Process?
    private var timer: Timer?
    private var connection: NWConnection?
    private let news = FirestormNewsView(frame: .zero)
    private let realmStatus = FirestormRealmView(frame: .zero)
    private let fixes = FirestormFixesView(frame: .zero)
    private let updates = LauncherUpdatesView()
    private var path = NSTextField(wrappingLabelWithString: L("Choose an existing game folder containing Data and _midnight_."))
    private var status = NSTextField(wrappingLabelWithString: L("Install the game or choose an existing client to begin."))
    private var network = NSTextField(labelWithString: L("●  Checking login endpoint…"))
    private var badge = NSTextField(labelWithString: L("NO GAME SELECTED"))
    private var detail = NSTextField(wrappingLabelWithString: "")
    private var language = NSPopUpButton()
    private var interfaceLanguage = NSPopUpButton()
    private let interfaceLanguageIDs = ["auto", "en", "ru"]
    private var launcherVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var progress = NSProgressIndicator()
    private var downloadBar = NSProgressIndicator()
    private var pause = NSButton(title: L("Pause"), target: nil, action: nil)
    private var installCancellation: InstallCancellation?
    private var pendingInstallDestination: URL?
    private var launchNoticeVisible = false
    private static var coldStartHint: String { L("First launch after a starter install may take around 10 minutes, or longer on slow connections. WoW may bounce in the Dock with no window while more data downloads. Please wait.") }
    private static var defaultHint: String { L("The macOS client is included. Install downloads ~297 MB of starter data from Firestorm; more world assets stream while you play.") }
    private var play = NSButton(title: L("Play"), target: nil, action: nil)
    private var mutationButtons: [NSButton] = []
    private let localeIDs = ["ruRU", "enUS", "enGB", "deDE", "frFR", "esES"]
    private var messages = [String]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.downloadUnavailableReason = { [weak self] in
            guard let self else { return "The launcher is not ready to update." }
            return self.busy ? "Wait for the current game operation to finish, then try again." : nil
        }
        updates.installationUnavailableReason = { [weak self] in
            guard let self else { return "The launcher is not ready to update." }
            if self.busy { return "Wait for the current game operation to finish, then try again." }
            if self.gameProcess?.isRunning == true || self.game?.isTerminated == false || LauncherCore.gameIsRunning() {
                return "Close World of Warcraft before installing the launcher update."
            }
            if self.window?.attachedSheet != nil {
                return "Close the open dialog before installing the launcher update."
            }
            return nil
        }
        updates.preparationChanged = { [weak self] in self?.updateButtons() }
        buildWindow()
        if let saved = UserDefaults.standard.string(forKey:"ClientRoot"), let found = try? GameInstallation.inspect(URL(fileURLWithPath:saved)) { selected = found }
        if selected == nil { selected = LauncherCore.candidates().compactMap { try? GameInstallation.inspect($0) }.first }
        displayPath()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        verify()
        checkNetwork()
        updates.startAutomaticChecks()
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.observeGame() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if busy || (updates.isPreparing && !updates.replacementStarted) { NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    func windowShouldClose(_ sender:NSWindow)->Bool { !busy && !updates.isPreparing }

    private func label(_ text:String,size:CGFloat = 13,weight:NSFont.Weight = .regular,color:NSColor = .labelColor)->NSTextField {
        let v = NSTextField(labelWithString:text)
        v.font = .systemFont(ofSize:size,weight:weight)
        v.textColor = color
        return v
    }
    private func button(_ title:String,_ selector:Selector,primary:Bool = false)->NSButton {
        let b = NSButton(title:title,target:self,action:selector)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if primary { b.bezelColor = amber; b.contentTintColor = .black; b.font = .systemFont(ofSize:16,weight:.bold) }
        mutationButtons.append(b)
        return b
    }
    private func column(_ views:[NSView],spacing:CGFloat = 12)->NSStackView {
        let stack = NSStackView(views:views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func row(_ views:[NSView],spacing:CGFloat = 8)->NSStackView {
        let stack = NSStackView(views:views); stack.spacing = spacing; stack.alignment = .centerY
        return stack
    }
    private func pin(_ v:NSView,in parent:NSView,insets:CGFloat = 0) {
        parent.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:insets),v.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-insets),v.topAnchor.constraint(equalTo:parent.topAnchor,constant:insets),v.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-insets)])
    }

    private func buildWindow() {
        if window == nil {
            window = NSWindow(contentRect:NSRect(x:0,y:0,width:1050,height:740),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        }
        mutationButtons.removeAll()
        news.removeFromSuperview()
        realmStatus.removeFromSuperview()
        fixes.removeFromSuperview()
        updates.removeFromSuperview()
        // Fresh controls let AppKit recreate intrinsic sizing and wrapping constraints.
        // Installation, download and running-game state live on the controller.
        path = NSTextField(wrappingLabelWithString: L("Choose an existing game folder containing Data and _midnight_."))
        status = NSTextField(wrappingLabelWithString: L("Install the game or choose an existing client to begin."))
        network = NSTextField(labelWithString: L("●  Checking login endpoint…"))
        badge = NSTextField(labelWithString: L("NO GAME SELECTED"))
        detail = NSTextField(wrappingLabelWithString: "")
        language = NSPopUpButton()
        interfaceLanguage = NSPopUpButton()
        progress = NSProgressIndicator()
        downloadBar = NSProgressIndicator()
        pause = NSButton(title: L("Pause"), target: nil, action: nil)
        play = NSButton(title: L("Play"), target: nil, action: nil)
        window.title = "Firestorm Launcher"
        window.appearance = NSAppearance(named:.darkAqua)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed:0.055,green:0.067,blue:0.09,alpha:1)
        let content = NSView(); window.contentView = content
        let sidebar = Surface(NSColor(calibratedRed:0.075,green:0.086,blue:0.11,alpha:1))
        sidebar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(sidebar)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:content.leadingAnchor),sidebar.topAnchor.constraint(equalTo:content.topAnchor),sidebar.bottomAnchor.constraint(equalTo:content.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:225)])
        let flame = label("♨",size:40,weight:.bold,color:amber)
        let brand = label("FIRESTORM",size:18,weight:.heavy)
        let edition = label(LF("MACOS LAUNCHER  /  %@", launcherVersion),size:10,weight:.semibold,color:muted)
        let gameTab = Surface(NSColor(calibratedRed:0.19,green:0.15,blue:0.13,alpha:1),radius:9)
        let tabText = column([label("WORLD OF WARCRAFT",size:9,weight:.bold,color:amber),label("Midnight",size:18,weight:.semibold)],spacing:5)
        pin(tabText,in:gameTab,insets:14)
        let links = column([button(L("Install game"),#selector(installGame)),button(L("Install location…"),#selector(chooseInstallLocation)),button(L("Firestorm website ↗"),#selector(openSite)),button(L("About launcher"),#selector(about))],spacing:10)
        interfaceLanguage.removeAllItems()
        interfaceLanguage.addItems(withTitles: [L("Automatic"), "English", "Русский"])
        let savedInterfaceLanguage = UserDefaults.standard.string(forKey: "LauncherLanguage") ?? "auto"
        interfaceLanguage.selectItem(at: interfaceLanguageIDs.firstIndex(of: savedInterfaceLanguage) ?? 0)
        interfaceLanguage.target = self
        interfaceLanguage.action = #selector(interfaceLanguageChanged)
        interfaceLanguage.setAccessibilityLabel(L("Interface language"))
        let interfacePreferences = column([label(L("Interface language"), size:12, color:muted), interfaceLanguage], spacing:6)
        let side = column([flame,brand,edition,label(L("LIBRARY"),size:10,weight:.bold,color:muted),gameTab,realmStatus,links,interfacePreferences],spacing:14)
        side.setCustomSpacing(30,after:edition)
        sidebar.addSubview(side); side.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([side.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:20),side.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18),side.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:30),gameTab.widthAnchor.constraint(equalTo:side.widthAnchor),realmStatus.widthAnchor.constraint(equalTo:side.widthAnchor)])
        let foot = label(L("Intel & Apple Silicon · macOS 14+\nCommunity launcher"),size:10,color:muted)
        sidebar.addSubview(foot); foot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([foot.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:20),foot.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-22)])

        let hero = HeroView(); hero.wantsLayer = true; hero.layer?.cornerRadius = 14; hero.layer?.masksToBounds = true
        let heroText = column([label("WORLD OF WARCRAFT",size:11,weight:.bold,color:amber),label("MIDNIGHT",size:46,weight:.heavy),label(L("Your journey to Silvermoon"),size:16,color:.secondaryLabelColor),label(L("12.0.7.68974  ·  Native macOS client"),size:11,color:muted)],spacing:8)
        hero.addSubview(heroText); heroText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([hero.heightAnchor.constraint(equalToConstant:140),heroText.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:26),heroText.centerYAnchor.constraint(equalTo:hero.centerYAnchor)])
        network.font = .systemFont(ofSize:11); network.textColor = muted
        badge.font = .systemFont(ofSize:10,weight:.bold); badge.textColor = amber
        let clientCard = Surface(NSColor(calibratedRed:0.09,green:0.106,blue:0.14,alpha:1),radius:12)
        path.font = .systemFont(ofSize:11); path.textColor = muted; path.isSelectable = true; path.maximumNumberOfLines = 2; path.lineBreakMode = .byTruncatingMiddle
        let choose = button(L("Locate game…"),#selector(choose))
        let finder = button(L("Show folder"),#selector(openFolder))
        let check = button(L("Verify"),#selector(verify))
        let cardStack = column([row([label(L("Game client"),size:15,weight:.semibold),badge],spacing:18),path,row([choose,check,finder])],spacing:12)
        pin(cardStack,in:clientCard,insets:18)
        language.removeAllItems()
        language.addItems(withTitles:[L("Russian"), L("English (US)"), L("English (UK)"), L("German"), L("French"), L("Spanish")])
        let savedLocale = UserDefaults.standard.string(forKey:"GameLocale") ?? "enUS"
        language.selectItem(at:localeIDs.firstIndex(of:savedLocale) ?? 0)
        language.target = self; language.action = #selector(localeChanged)
        let actions = row([button(L("Repair client"),#selector(repair)),button(L("Create separate copy…"),#selector(clone)),button(L("Restore backup"),#selector(restore))])
        let prefs = row([label(L("Game language"),size:12,color:muted),language,button(L("Logs"),#selector(openLogs)),button(L("Reset cache"),#selector(clearCache))],spacing:12)
        status.font = .systemFont(ofSize:13,weight:.medium); status.isSelectable = true; status.maximumNumberOfLines = 3
        detail.font = .systemFont(ofSize:10); detail.textColor = muted; detail.maximumNumberOfLines = 2
        detail.stringValue = Self.defaultHint
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        downloadBar.style = .bar; downloadBar.isIndeterminate = false; downloadBar.minValue = 0; downloadBar.maxValue = 1; downloadBar.isHidden = true
        pause.title = L("Pause")
        pause.target = self; pause.action = #selector(pauseInstall); pause.bezelStyle = .rounded; pause.isHidden = true
        play.target = self; play.action = #selector(launch); play.bezelStyle = .rounded; play.controlSize = .large; play.bezelColor = amber; play.contentTintColor = .black; play.font = .systemFont(ofSize:18,weight:.bold); play.keyEquivalent = "\r"
        let bottom = row([progress,play,pause],spacing:12)
        // Browsing news can extend the page without moving Play or installation
        // progress offscreen. The document remains top-aligned on small displays.
        let main = column([row([label(L("GAMES  /  MIDNIGHT"),size:11,weight:.bold,color:muted),network],spacing:34),updates,hero,news,clientCard,actions,prefs,fixes],spacing:12)
        main.detachesHiddenViews = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = LauncherScrollDocument()
        scroll.documentView = document
        document.addSubview(main)
        document.translatesAutoresizingMaskIntoConstraints = false
        main.translatesAutoresizingMaskIntoConstraints = false
        let footer = column([status,detail,downloadBar,bottom],spacing:8)
        content.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer); footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:28),
            scroll.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-28),
            scroll.topAnchor.constraint(equalTo:content.topAnchor,constant:25),
            scroll.bottomAnchor.constraint(equalTo:footer.topAnchor,constant:-16),
            footer.leadingAnchor.constraint(equalTo:scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo:scroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-22),
            document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            main.leadingAnchor.constraint(equalTo:document.leadingAnchor),
            main.trailingAnchor.constraint(equalTo:document.trailingAnchor),
            main.topAnchor.constraint(equalTo:document.topAnchor),
            main.bottomAnchor.constraint(equalTo:document.bottomAnchor),
            hero.widthAnchor.constraint(equalTo:main.widthAnchor),
            updates.widthAnchor.constraint(equalTo:main.widthAnchor),
            news.widthAnchor.constraint(equalTo:main.widthAnchor),
            fixes.widthAnchor.constraint(equalTo:main.widthAnchor),
            clientCard.widthAnchor.constraint(equalTo:main.widthAnchor),
            path.widthAnchor.constraint(equalTo:cardStack.widthAnchor),
            status.widthAnchor.constraint(equalTo:footer.widthAnchor),
            detail.widthAnchor.constraint(equalTo:footer.widthAnchor),
            downloadBar.widthAnchor.constraint(equalTo:footer.widthAnchor),
            play.widthAnchor.constraint(equalToConstant:188),
            play.heightAnchor.constraint(equalToConstant:44),
        ])
        news.reload(language: LauncherLocalization.language)
        realmStatus.reload(language: LauncherLocalization.language)
        fixes.reload(language: LauncherLocalization.language)
        updates.refreshLocalization()
        updateButtons()
    }

    @objc private func interfaceLanguageChanged() {
        guard !busy, !updates.isPreparing else { return }
        let index = interfaceLanguage.indexOfSelectedItem
        guard interfaceLanguageIDs.indices.contains(index) else { return }
        let badgeKey = InterfaceTranslations.russian.first { $0.value == badge.stringValue }?.key ?? badge.stringValue
        let networkKey = InterfaceTranslations.russian.first { $0.value == network.stringValue }?.key ?? network.stringValue
        let networkColor = network.textColor
        UserDefaults.standard.set(interfaceLanguageIDs[index], forKey: "LauncherLanguage")
        buildWindow()
        badge.stringValue = L(badgeKey)
        network.stringValue = L(networkKey)
        network.textColor = networkColor
        displayPath()
        if pendingInstallDestination != nil {
            detail.stringValue = L("Downloaded parts are saved. Keep the same game language and click Resume install or Install game to continue.")
        }
        Launcher.updateMenu()
        log(L("Interface language changed."))
    }

    private var locale:String { localeIDs[max(0,language.indexOfSelectedItem)] }
    @objc private func localeChanged() { UserDefaults.standard.set(locale,forKey:"GameLocale"); log(LF("Game language selected: %@.", language.titleOfSelectedItem ?? locale)) }
    private var installDestination:URL { UserDefaults.standard.string(forKey:"InstallDestination").map { URL(fileURLWithPath:$0,isDirectory:true) } ?? CleanInstaller.defaultDestination }
    private func displayPath() {
        if let pendingInstallDestination { path.stringValue = LF("Install location: %@", pendingInstallDestination.path) }
        else { path.stringValue = selected?.root.path ?? LF("Install location: %@", installDestination.path) }
        path.toolTip = path.stringValue
        if pendingInstallDestination == nil {
            detail.stringValue = selected.flatMap { coldStartNoticeIdentity(for:$0) } == nil ? Self.defaultHint : Self.coldStartHint
        }
    }
    private func log(_ text:String,error:Bool = false) { status.stringValue = text; status.textColor = error ? .systemRed : .labelColor; messages.append("\(Date().formatted(date:.omitted,time:.standard))  \(text)") }
    private func updateButtons() {
        let controlsEnabled = !busy && !updates.isPreparing
        for b in mutationButtons { b.isEnabled = controlsEnabled }
        language.isEnabled = controlsEnabled
        interfaceLanguage.isEnabled = controlsEnabled
        play.isEnabled = controlsEnabled
        if pendingInstallDestination != nil { play.title = installCancellation == nil ? L("Resume install") : L("Installing…") }
        else { play.title = selected == nil ? L("Install") : (gameProcess?.isRunning == true || game?.isTerminated == false ? L("Return to game") : L("Play")) }
        pause.isHidden = installCancellation == nil
        pause.isEnabled = installCancellation != nil
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    private func saveSelection(_ game:GameInstallation) { pendingInstallDestination = nil; selected = game; UserDefaults.standard.set(game.root.path,forKey:"ClientRoot"); displayPath() }
    @objc private func chooseInstallLocation() {
        guard !busy, !updates.isPreparing else { return }
        let panel = NSSavePanel(); panel.title = L("Install Firestorm Midnight"); panel.nameFieldStringValue = "Firestorm Midnight"; panel.canCreateDirectories = true
        panel.directoryURL = installDestination.deletingLastPathComponent()
        panel.message = L("Choose a new folder. The macOS client is included and starter Data downloads directly from Firestorm.")
        panel.beginSheetModal(for:window) { response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path,forKey:"InstallDestination")
            self.pendingInstallDestination = nil
            self.displayPath(); self.updateButtons(); self.log(LF("Install location: %@. Click Install game to begin.", url.path))
        }
    }
    @objc private func installGame() {
        guard !busy, !updates.isPreparing else { return }
        let target = pendingInstallDestination ?? installDestination
        if FileManager.default.fileExists(atPath:target.path) {
            if let existing = try? GameInstallation.inspect(target) { saveSelection(existing); verify() }
            else { log(L("The install location already exists. Choose a new folder with Install location…"),error:true) }
            return
        }
        pendingInstallDestination = target
        displayPath()
        let token = InstallCancellation(); installCancellation = token
        busy = true; downloadBar.isHidden = false; downloadBar.doubleValue = 0; updateButtons()
        badge.stringValue = L("INSTALLING")
        log(L("Installing the bundled macOS client and downloading starter Data from Firestorm…"))
        let currentLocale = locale
        let installer = CleanInstaller(core:core)
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try installer.install(to:target,locale:currentLocale,cancellation:token) { item in
                DispatchQueue.main.async {
                    self.status.stringValue = item.message
                    self.downloadBar.doubleValue = item.fraction
                    let size = ByteCountFormatter.string(fromByteCount:item.completedBytes,countStyle:.file)
                    let total = ByteCountFormatter.string(fromByteCount:item.totalBytes,countStyle:.file)
                    let speed = item.bytesPerSecond > 0 ? " · " + ByteCountFormatter.string(fromByteCount:Int64(item.bytesPerSecond),countStyle:.file) + L("/s") : ""
                    self.detail.stringValue = LF("%@ / %@%@ · Downloads resume if interrupted.", size, total, speed)
                }
            } }
            DispatchQueue.main.async {
                self.busy = false; self.installCancellation = nil; self.downloadBar.isHidden = true
                switch result {
                case .success(let installed):self.saveSelection(installed); self.badge.stringValue = L("READY TO PLAY"); self.log(L("Installed. Click Play to start Firestorm.")); self.detail.stringValue = Self.coldStartHint
                case .failure(let error):self.badge.stringValue = L("INSTALL PAUSED"); self.log(error.localizedDescription,error:!token.isCancelled); self.detail.stringValue = L("Downloaded parts are saved. Keep the same game language and click Resume install or Install game to continue.")
                }
                self.updateButtons()
            }
        }
    }
    @objc private func pauseInstall() { installCancellation?.cancel(); pause.isEnabled = false; log(L("Pausing… Downloaded parts will be kept.")) }
    private func work(_ operation:@escaping (@escaping (String)->Void)throws->String,then:(()->Void)? = nil) {
        guard !busy, !updates.isPreparing else { return }
        busy = true; updateButtons()
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try operation { message in DispatchQueue.main.async { self.log(message) } } }
            DispatchQueue.main.async {
                self.busy = false
                switch result { case .success(let message):self.log(message); then?(); case .failure(let error):self.log(error.localizedDescription,error:true) }
                self.updateButtons()
            }
        }
    }

    @objc private func choose() {
        let panel = NSOpenPanel(); panel.title = L("Choose a Midnight client folder with Data and _midnight_"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url = panel.url else { return }
            do { self.saveSelection(try GameInstallation.inspect(url)); self.verify() } catch { self.log(error.localizedDescription,error:true) }
        }
    }
    @objc private func verify() {
        guard let selected else { updateButtons(); return }
        log(L("Verifying game client and launcher files…"))
        var patched = false
        work({ _ in let result = try self.core.check(selected); patched = result.patched; return result.message },then:{
            self.badge.stringValue = patched ? L("READY TO PLAY") : L("SETUP REQUIRED")
        })
    }
    @objc private func repair() {
        guard let selected else { choose(); return }
        let currentLocale = locale
        work({ progress in try self.core.prepare(selected,locale:currentLocale,progress:progress); return L("Client repaired. The Firestorm profile is ready.") },then:{self.badge.stringValue = L("READY TO PLAY")})
    }
    @objc private func clone() {
        guard let source = selected else { choose(); return }
        let panel = NSSavePanel(); panel.title = L("Create a separate Firestorm installation"); panel.nameFieldStringValue = "Firestorm Midnight"; panel.canCreateDirectories = true
        panel.message = L("Choose a new folder on APFS. Game archives are cloned without downloading them again. Account data and cache are not copied.")
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let destination = panel.url else { return }
            let currentLocale = self.locale
            var created:GameInstallation?
            self.work({ progress in created = try self.core.cloneInstall(from:source,to:destination,locale:currentLocale,progress:progress); return L("Separate client installed and selected for launch.") },then:{if let created { self.saveSelection(created); self.badge.stringValue = L("READY TO PLAY") }})
        }
    }
    @objc private func restore() {
        guard let selected else { return }
        let alert = NSAlert(); alert.messageText = L("Restore the previous client?"); alert.informativeText = L("This restores the game application and Firestorm settings from the latest backup. Game archives stay in place."); alert.addButton(withTitle:L("Restore")); alert.addButton(withTitle:L("Cancel"))
        alert.beginSheetModal(for:window) { response in guard response == .alertFirstButtonReturn else { return }; self.work({ progress in try self.core.restoreLatest(selected,progress:progress); return L("Previous client and settings restored.") },then:{self.badge.stringValue = L("VERIFY CLIENT")}) }
    }
    @objc private func launch() {
        guard !busy, !updates.isPreparing, !launchNoticeVisible else { return }
        if pendingInstallDestination != nil { installGame(); return }
        guard let selected else { installGame(); return }
        if let process = gameProcess, process.isRunning,
           process.executableURL == selected.app.appendingPathComponent("Contents/MacOS/World of Warcraft") {
            NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: [])
            updateButtons()
            return
        }
        if let running = NSWorkspace.shared.runningApplications.first(where:{$0.bundleURL?.standardizedFileURL == selected.app.standardizedFileURL && !$0.isTerminated}) { game = running; running.activate(options:[]); updateButtons(); return }
        if let identity = coldStartNoticeIdentity(for:selected),
           !(UserDefaults.standard.stringArray(forKey:"AcknowledgedColdStartNotices") ?? []).contains(identity) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L("The first launch can take a while")
            alert.informativeText = L("When only the starter data from Firestorm is installed, World of Warcraft may need around 10 minutes to download and prepare more data before its window appears. Slower connections may take longer.\n\nThe WoW icon may keep bouncing in the Dock without showing a window during this time. Please keep the game open and wait.")
            alert.addButton(withTitle:L("Launch game"))
            alert.addButton(withTitle:L("Cancel"))
            launchNoticeVisible = true
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { return }
                self.launchNoticeVisible = false
                guard response == .alertFirstButtonReturn else { return }
                var seen = UserDefaults.standard.stringArray(forKey:"AcknowledgedColdStartNotices") ?? []
                if !seen.contains(identity) { seen.append(identity) }
                UserDefaults.standard.set(Array(seen.suffix(100)),forKey:"AcknowledgedColdStartNotices")
                self.prepareAndLaunch(selected)
            }
            return
        }
        prepareAndLaunch(selected)
    }
    /// The marker is present for starter installs and repaired older starter
    /// stores. Its creation date distinguishes a fresh reinstall at the same path.
    private func coldStartNoticeIdentity(for game:GameInstallation)->String? {
        let marker = game.root.appendingPathComponent("Data/data/.firestorm-index-format")
        guard let attributes = try? marker.resourceValues(forKeys:[.isRegularFileKey,.creationDateKey,.contentModificationDateKey]),
              attributes.isRegularFile == true else { return nil }
        let date = attributes.creationDate ?? attributes.contentModificationDate ?? Date(timeIntervalSince1970:0)
        return game.root.resolvingSymlinksInPath().standardizedFileURL.path + "|" + String(date.timeIntervalSince1970)
    }
    private func prepareAndLaunch(_ selected:GameInstallation) {
        let currentLocale = locale
        work({ progress in try self.core.prepare(selected,locale:currentLocale,progress:progress); return L("Launching game…") },then:{self.openGame(selected)})
    }
    private func openGame(_ selected:GameInstallation) {
        let starterInstall = coldStartNoticeIdentity(for:selected) != nil
        busy = true; updateButtons()
        if starterInstall {
            detail.stringValue = Self.coldStartHint
            log(L("Starting WoW. The first launch may take around 10 minutes before a window appears…"))
        } else { log(L("Starting WoW…")) }
        do {
            let process = try core.launch(selected)
            gameProcess = process
            game = NSRunningApplication(processIdentifier: process.processIdentifier)
            log(starterInstall ? L("Game process started. If no window is visible yet, please wait while startup finishes.") : L("Game process started. Sign in from the World of Warcraft window."))
            badge.stringValue = L("GAME RUNNING")
        } catch {
            gameProcess = nil
            game = nil
            log(error.localizedDescription,error:true)
        }
        busy = false; updateButtons()
    }
    private func observeGame() {
        if let process = gameProcess {
            if process.isRunning {
                game = NSRunningApplication(processIdentifier: process.processIdentifier)
                return
            }
            gameProcess = nil
            game = nil
            if !busy {
                let status = process.terminationStatus
                log(status == 0 ? L("The game has exited.") : LF("The game exited with code %d. Open Logs to inspect GameLaunch.log.", status), error: status != 0)
                badge.stringValue = L("READY TO PLAY")
                updateButtons()
            }
            return
        }
        if let game,game.isTerminated { self.game = nil; if !busy { log(L("The game has exited.")); badge.stringValue = L("READY TO PLAY"); updateButtons() } }
    }
    @objc private func openFolder() {
        if let target = pendingInstallDestination { NSWorkspace.shared.open(CleanInstaller.stagingDirectory(for:target)) }
        else if let selected { NSWorkspace.shared.open(selected.root) }
    }
    @objc private func openLogs() {
        if let target = pendingInstallDestination {
            let downloads = CleanInstaller.stagingDirectory(for:target).appendingPathComponent("downloads",isDirectory:true)
            let log = downloads.appendingPathComponent("download.log")
            if FileManager.default.fileExists(atPath:log.path) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
            else if FileManager.default.fileExists(atPath:downloads.path) { NSWorkspace.shared.open(downloads) }
            else { self.log(L("No download log has been created yet.")) }
            return
        }
        guard let selected else { return }
        try? FileManager.default.createDirectory(at:selected.logs,withIntermediateDirectories:true)
        NSWorkspace.shared.open(selected.logs)
    }
    @objc private func clearCache() {
        guard let selected,!LauncherCore.gameIsRunning() else { log(L("Close World of Warcraft first."),error:true); return }
        let cache = selected.product.appendingPathComponent("Cache")
        guard FileManager.default.fileExists(atPath:cache.path) else { log(L("The cache is already empty.")); return }
        do {
            let real = cache.resolvingSymlinksInPath().standardizedFileURL
            guard real.path.hasPrefix(selected.product.path + "/") else { throw NSError(domain:"Launcher",code:1,userInfo:[NSLocalizedDescriptionKey:L("The cache is outside the selected game folder.")]) }
            let backup = selected.product.appendingPathComponent("Cache.saved-\(UUID().uuidString)")
            try FileManager.default.moveItem(at:cache,to:backup)
            log(L("Cache reset. The previous cache folder is saved beside the game."))
        } catch { log(error.localizedDescription,error:true) }
    }
    @objc private func openSite() { NSWorkspace.shared.open(URL(string:"https://firestorm-servers.com/en/welcome")!) }
    @objc private func openDownloads() { NSWorkspace.shared.open(URL(string:"https://firestorm-servers.com/en/play")!) }
    @objc private func about() {
        let a = NSAlert(); a.messageText = "Firestorm Launcher \(launcherVersion)"
        a.informativeText = L("Community launcher for Midnight 12.0.7.68974.\nIntel & Apple Silicon · macOS 14 or later.\n\nIncludes the supplied macOS client, backups, recovery, and the Silvermoon connection profile. Use a separate game copy for Firestorm.\n\nInstall game data from Firestorm or choose an existing installation. New game builds and a full scan of all game archives are not supported. Enter your password only in the game.")
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Check for updates…"))
        a.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.updates.checkForUpdates()
        }
    }
    private func checkNetwork() {
        let c = NWConnection(host:"eu.mnight.fstorm.eu",port:1119,using:.tcp); connection = c
        var complete = false
        c.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                guard !complete else { return }
                switch state {
                case .ready: complete = true; self.network.stringValue = L("●  Login endpoint reachable"); self.network.textColor = .systemGreen; c.cancel()
                case .failed: complete = true; self.network.stringValue = L("●  Login endpoint unavailable"); self.network.textColor = muted; c.cancel()
                default:break
                }
            }
        }
        c.start(queue:DispatchQueue.global(qos:.utility))
        DispatchQueue.main.asyncAfter(deadline:.now()+6) {
            guard !complete else { return }; complete = true; c.cancel(); self.network.stringValue = L("●  Login endpoint did not respond"); self.network.textColor = muted
        }
    }
}
