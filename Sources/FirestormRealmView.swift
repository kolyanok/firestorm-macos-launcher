import AppKit

/// Realm population is supplied by Firestorm's realm API. It is deliberately
/// separate from the launcher's TCP reachability check for the login endpoint.
@MainActor
final class FirestormRealmView: NSView {
    private let service = FirestormRealmService()
    private let heading = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "Silvermoon")
    private let state = NSTextField(wrappingLabelWithString: "")
    private let population = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton()
    private var realm: FirestormRealmStatus?
    private var request: URLSessionDataTask?
    private var requestID = UUID()
    private var attempted = false
    private var loading = false
    private var failed = false
    private var currentLanguage = "en"
    private var lastRequestAt = Date.distantPast
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.106, blue: 0.14, alpha: 1).cgColor
        layer?.cornerRadius = 9
        heading.font = .systemFont(ofSize: 10, weight: .medium)
        heading.textColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        state.font = .systemFont(ofSize: 11, weight: .medium)
        state.maximumNumberOfLines = 2
        state.lineBreakMode = .byWordWrapping
        population.font = .systemFont(ofSize: 11)
        population.textColor = .secondaryLabelColor
        population.maximumNumberOfLines = 2
        population.lineBreakMode = .byWordWrapping
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refresh.isBordered = false
        refresh.controlSize = .small
        refresh.target = self
        refresh.action = #selector(refreshRealm)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, refresh])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        let stack = NSStackView(views: [header, name, state, population])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -9),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            state.widthAnchor.constraint(equalTo: stack.widthAnchor),
            population.widthAnchor.constraint(equalTo: stack.widthAnchor),
            refresh.widthAnchor.constraint(equalToConstant: 18),
            refresh.heightAnchor.constraint(equalToConstant: 16),
            state.heightAnchor.constraint(equalToConstant: 27),
            population.heightAnchor.constraint(equalToConstant: 27),
            heightAnchor.constraint(equalToConstant: 116),
        ])
        render()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true, !self.loading,
                      Date().timeIntervalSince(self.lastRequestAt) >= 120 else { return }
                self.reload(language: self.currentLanguage, force: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTimer?.invalidate() }

    func reload(language: String, force: Bool = false) {
        currentLanguage = language == "ru" ? "ru" : "en"
        if force { service.invalidateCache() }
        if attempted && !force {
            render()
            return
        }
        attempted = true
        requestID = UUID()
        let generation = requestID
        request?.cancel()
        loading = true
        failed = false
        lastRequestAt = Date()
        render()
        request = service.load { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == generation else { return }
                self.request = nil
                self.loading = false
                switch result {
                case .success(let realm):
                    self.realm = realm
                    self.failed = false
                case .failure:
                    self.failed = true
                }
                self.render()
            }
        }
    }

    private func render() {
        heading.stringValue = L("Realm status")
        refresh.toolTip = L("Refresh realm status")
        refresh.setAccessibilityLabel(L("Refresh realm status"))
        refresh.isEnabled = !loading
        name.stringValue = realm?.name ?? "Silvermoon"
        state.textColor = .secondaryLabelColor
        population.textColor = .secondaryLabelColor
        toolTip = nil
        if failed {
            state.stringValue = L("Status unavailable")
            if let realm, let count = realm.playersOnline {
                population.stringValue = LF("Last known: %@ players", format(count))
            } else {
                population.stringValue = L("Try refreshing the realm status.")
            }
            return
        }
        guard let realm else {
            state.stringValue = loading ? L("Checking realm status…") : L("Realm status has not loaded yet.")
            population.stringValue = ""
            return
        }
        if realm.isOnline {
            state.stringValue = realm.isLocked ? L("● Online · Restricted") : L("● Online")
            state.textColor = realm.isLocked ? .systemOrange : .systemGreen
            population.stringValue = realm.playersOnline.map { LF("%@ players online", format($0)) }
                ?? L("Player count unavailable")
        } else {
            state.stringValue = L("● Offline")
            state.textColor = .systemRed
            population.stringValue = L("Realm is currently offline.")
        }
        if let updatedAt = realm.updatedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: currentLanguage == "ru" ? "ru_RU" : "en_US")
            formatter.timeStyle = .medium
            toolTip = LF("Last realm update: %@", formatter.string(from: updatedAt))
        }
    }

    private func format(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currentLanguage == "ru" ? "ru_RU" : "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }

    @objc private func refreshRealm() { reload(language: currentLanguage, force: true) }
}
