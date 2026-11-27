import AppKit

@main
struct Launcher {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let mode = arguments.first,mode.hasPrefix("--") {
            do {
                let core = LauncherCore()
                let report:(String)->Void = { print($0) }
                switch mode {
                case "--check" where arguments.count == 2:
                    let game = try GameInstallation.inspect(URL(fileURLWithPath:arguments[1]))
                    let state = try core.check(game)
                    print("\(game.version)\n\(state.message)\n\(game.root.path)")
                case "--prepare" where arguments.count == 2:
                    try core.prepare(GameInstallation.inspect(URL(fileURLWithPath:arguments[1])),locale:"ruRU",progress:report)
                case "--clone" where arguments.count == 3:
                    let result = try core.cloneInstall(from:GameInstallation.inspect(URL(fileURLWithPath:arguments[1])),to:URL(fileURLWithPath:arguments[2]),locale:"ruRU",progress:report)
                    print(result.root.path)
                case "--restore" where arguments.count == 2:
                    try core.restoreLatest(GameInstallation.inspect(URL(fileURLWithPath:arguments[1])),progress:report)
                case "--install" where (2...3).contains(arguments.count):
                    let locale = arguments.count == 3 ? arguments[2] : "enUS"
                    let result = try CleanInstaller(core:core).install(to:URL(fileURLWithPath:arguments[1]),locale:locale,cancellation:InstallCancellation()) { progress in
                        print("\(progress.message) \(Int(progress.fraction * 100))%")
                    }
                    print(result.root.path)
                default:
                    throw NSError(domain:"Launcher",code:2,userInfo:[NSLocalizedDescriptionKey:L("Usage: --install PATH [enUS|ruRU] | --check PATH | --prepare PATH | --clone SOURCE DEST | --restore PATH")])
                }
                return
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        let app = NSApplication.shared
        let controller = AppController()
        app.setActivationPolicy(.regular); app.delegate = controller
        updateMenu()
        withExtendedLifetime(controller) { app.run() }
    }

    @MainActor static func updateMenu() {
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle:L("Quit Firestorm Launcher"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); item.submenu = appMenu
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title:L("Edit"))
        edit.addItem(withTitle:L("Copy"),action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:L("Paste"),action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:L("Select All"),action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"); editItem.submenu = edit
        NSApp.mainMenu = menu
    }
}
