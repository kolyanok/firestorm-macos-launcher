import AppKit

/// Latest fixes use native attributed text, including the source's Wowhead
/// links. The bounded inner scroll area keeps the Play footer in place.
@MainActor
final class FirestormFixesView: NSView, NSTextViewDelegate {
    private let service = FirestormFixesService()
    private let heading = NSTextField(labelWithString: "")
    private let refresh = NSButton()
    private let fullNotes = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let card = NSView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let bodyScroll = NSScrollView()
    private let body = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 220))
    private var item: FirestormFixesItem?
    private var request: URLSessionDataTask?
    private var requestID = UUID()
    private var attemptedLanguage: String?
    private var currentLanguage = "en"
    private var loading = false
    private var failed = false
    private var displayedText = ""
    private var displayedLinks: [FirestormTextLink] = []
    private var displayedBoldRanges: [NSRange] = []
    private var lastRequestAt = Date.distantPast
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        refresh.bezelStyle = .rounded
        refresh.target = self
        refresh.action = #selector(refreshFixes)
        fullNotes.bezelStyle = .rounded
        fullNotes.target = self
        fullNotes.action = #selector(openFullNotes)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = true
        body.importsGraphics = false
        body.isAutomaticLinkDetectionEnabled = false
        body.delegate = self
        body.linkTextAttributes = [
            .foregroundColor: NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.85, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        body.drawsBackground = false
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.textContainerInset = NSSize(width: 3, height: 6)
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.minSize = NSSize(width: 0, height: 0)
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        bodyScroll.documentView = body
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.borderType = .noBorder

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.106, blue: 0.14, alpha: 1).cgColor
        card.layer?.cornerRadius = 12
        let content = NSStackView(views: [title, date, bodyScroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        card.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            date.widthAnchor.constraint(equalTo: content.widthAnchor),
            bodyScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            bodyScroll.heightAnchor.constraint(equalToConstant: 220),
        ])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, spinner, refresh])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let stack = NSStackView(views: [header, message, card, fullNotes])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        render()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true, !self.loading,
                      Date().timeIntervalSince(self.lastRequestAt) >= 5 * 60 else { return }
                self.reload(language: self.currentLanguage, force: true)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTimer?.invalidate() }

    func reload(language: String, force: Bool = false) {
        currentLanguage = language == "ru" ? "ru" : "en"
        if force { service.invalidateCache() }
        if !force && attemptedLanguage == currentLanguage {
            render()
            return
        }
        requestID = UUID()
        let generation = requestID
        request?.cancel()
        request = nil
        if attemptedLanguage != currentLanguage { item = nil }
        attemptedLanguage = currentLanguage
        loading = true
        failed = false
        render()
        let requestedAt = Date()
        request = service.load(language: currentLanguage) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == generation else { return }
                self.request = nil
                self.loading = false
                switch result {
                case .success(let fixes):
                    self.item = fixes.first
                    self.failed = false
                case .failure:
                    self.failed = true
                }
                self.render()
            }
        }
        if request != nil { lastRequestAt = requestedAt }
    }

    private func render() {
        heading.stringValue = L("Latest fixes")
        refresh.title = L("Refresh")
        refresh.setAccessibilityLabel(L("Refresh latest fixes"))
        refresh.isEnabled = !loading
        fullNotes.title = L("Full patch notes ↗")
        body.setAccessibilityLabel(L("Latest fixes text"))
        if loading {
            spinner.startAnimation(nil)
            message.stringValue = L("Loading latest fixes…")
        } else {
            spinner.stopAnimation(nil)
            message.stringValue = failed
                ? L("Latest fixes could not be loaded. Try Refresh or open the full patch notes.")
                : L("No fixes have been published yet.")
        }
        message.isHidden = !loading && !failed && item != nil
        card.isHidden = item == nil
        guard let item else { return }
        title.stringValue = item.title
        title.toolTip = item.title
        date.stringValue = ""
        if let publishedAt = item.publishedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: currentLanguage == "ru" ? "ru_RU" : "en_US")
            formatter.dateStyle = .medium
            date.stringValue = formatter.string(from: publishedAt)
        }
        if displayedText != item.bodyText || displayedLinks != item.bodyLinks
            || displayedBoldRanges != item.bodyBoldRanges {
            let textChanged = displayedText != item.bodyText
            let previousOrigin = bodyScroll.contentView.bounds.origin
            let previousSelection = body.selectedRanges
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 5
            let text = NSMutableAttributedString(string: item.bodyText, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
            let length = (item.bodyText as NSString).length
            for range in item.bodyBoldRanges {
                guard range.location != NSNotFound, range.location >= 0,
                      range.location <= length, range.length > 0,
                      range.length <= length - range.location else { continue }
                text.addAttributes([
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.labelColor,
                ], range: range)
            }
            for link in item.bodyLinks {
                let range = link.range
                guard range.location != NSNotFound, range.location >= 0,
                      range.location <= length, range.length > 0,
                      range.length <= length - range.location,
                      let url = Self.allowedWowheadURL(link.url) else { continue }
                text.addAttribute(.link, value: url, range: range)
            }
            body.textStorage?.setAttributedString(text)
            body.sizeToFit()
            displayedText = item.bodyText
            displayedLinks = item.bodyLinks
            displayedBoldRanges = item.bodyBoldRanges
            if !textChanged { body.selectedRanges = previousSelection }
            bodyScroll.contentView.scroll(to: textChanged ? .zero : previousOrigin)
            bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Handle every link ourselves, including rejected values, so AppKit
        // cannot fall through to opening another scheme or an unexpected host.
        if let url = Self.allowedWowheadURL(link) { NSWorkspace.shared.open(url) }
        return true
    }

    private static func allowedWowheadURL(_ value: Any) -> URL? {
        let url: URL?
        if let value = value as? URL { url = value }
        else if let value = value as? String { url = URL(string: value) }
        else { url = nil }
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        return FirestormAPI.wowheadURL(url.absoluteString)
    }

    @objc private func refreshFixes() { reload(language: currentLanguage, force: true) }

    @objc private func openFullNotes() {
        if let url = URL(string: "https://firestorm-servers.com/\(currentLanguage)/news/dev") {
            NSWorkspace.shared.open(url)
        }
    }
}
