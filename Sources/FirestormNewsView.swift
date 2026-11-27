import AppKit
import ImageIO

/// Official Firestorm articles are displayed as native controls. Article HTML is
/// never executed in the launcher; links open in the user's default browser.
@MainActor
final class FirestormNewsView: NSView {
    private let service = FirestormNewsService()
    private let heading = NSTextField(labelWithString: "")
    private let refresh = NSButton()
    private let allNews = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cards = NSStackView()
    private var cardsHeight: NSLayoutConstraint!
    private var items: [FirestormNewsItem] = []
    private var request: URLSessionDataTask?
    private var requestID = UUID()
    private var attemptedLanguage: String?
    private var currentLanguage = "en"
    private var loading = false
    private var failed = false
    private var lastRequestAt = Date.distantPast
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        refresh.target = self
        refresh.action = #selector(refreshNews)
        refresh.bezelStyle = .rounded
        allNews.target = self
        allNews.action = #selector(openAllNews)
        allNews.bezelStyle = .rounded
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, spinner, refresh, allNews])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)

        cards.orientation = .horizontal
        cards.alignment = .top
        cards.distribution = .fillEqually
        cards.spacing = 10
        let stack = NSStackView(views: [header, message, cards])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardsHeight = cards.heightAnchor.constraint(equalToConstant: 170)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cardsHeight,
        ])
        render()
        // The view survives interface rebuilds, so there is only one timer.
        // Check visibility periodically and refresh after 30 minutes, including
        // after a manual refresh, without waking a hidden launcher to fetch.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.window?.isVisible == true, !self.loading,
                      Date().timeIntervalSince(self.lastRequestAt) >= 30 * 60 else { return }
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
        if attemptedLanguage != currentLanguage { items.removeAll() }
        attemptedLanguage = currentLanguage
        failed = false
        loading = true
        render()
        let requestedAt = Date()
        request = service.load(language: currentLanguage) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == generation else { return }
                self.request = nil
                self.loading = false
                switch result {
                case .success(let articles):
                    self.items = Array(articles.prefix(3))
                    self.failed = false
                case .failure:
                    self.failed = true
                }
                self.render()
            }
        }
        // A locale-only decode may reuse the service's cached response. Keep
        // the age of that response rather than delaying the next real refresh.
        if request != nil { lastRequestAt = requestedAt }
    }

    private func render() {
        heading.stringValue = L("Firestorm news")
        refresh.title = L("Refresh")
        refresh.setAccessibilityLabel(L("Refresh news"))
        refresh.isEnabled = !loading
        allNews.title = L("All news ↗")
        if loading {
            spinner.startAnimation(nil)
            message.stringValue = L("Loading Firestorm news…")
        } else {
            spinner.stopAnimation(nil)
            message.stringValue = failed ? L("News could not be loaded. Try Refresh or open the Firestorm website.") : L("No news is available yet.")
        }
        message.isHidden = !loading && !failed && !items.isEmpty
        for card in cards.arrangedSubviews {
            cards.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
        for item in items {
            let card = FirestormNewsCard(item: item, language: currentLanguage)
            cards.addArrangedSubview(card)
            card.heightAnchor.constraint(equalToConstant: 170).isActive = true
        }
        cards.isHidden = items.isEmpty
        cardsHeight.isActive = !items.isEmpty
    }

    @objc private func refreshNews() { reload(language: currentLanguage, force: true) }

    @objc private func openAllNews() {
        if let url = URL(string: "https://firestorm-servers.com/\(currentLanguage)/news") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class FirestormNewsCard: NSView {
    private let item: FirestormNewsItem

    init(item: FirestormNewsItem, language: String) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.106, blue: 0.14, alpha: 1).cgColor
        layer?.cornerRadius = 10
        let image = FirestormNewsImageView(url: item.imageURL)
        let title = NSTextField(wrappingLabelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        title.toolTip = item.title
        let date = NSTextField(labelWithString: "")
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        if let publishedAt = item.publishedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language == "ru" ? "ru_RU" : "en_US")
            formatter.dateStyle = .medium
            date.stringValue = formatter.string(from: publishedAt)
        }
        let read = NSButton(title: L("Read article ↗"), target: self, action: #selector(openArticle))
        read.isBordered = false
        read.font = .systemFont(ofSize: 11, weight: .medium)
        read.contentTintColor = NSColor(calibratedRed: 1, green: 0.66, blue: 0.27, alpha: 1)
        read.alignment = .left
        read.toolTip = item.articleURL.absoluteString
        read.setAccessibilityLabel("\(L("Read article ↗")): \(item.title)")
        let content = NSStackView(views: [image, title, date, read])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            image.widthAnchor.constraint(equalTo: content.widthAnchor),
            image.heightAnchor.constraint(equalToConstant: 68),
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            title.heightAnchor.constraint(equalToConstant: 32),
            date.widthAnchor.constraint(equalTo: content.widthAnchor),
            date.heightAnchor.constraint(equalToConstant: 13),
            read.widthAnchor.constraint(equalTo: content.widthAnchor),
            read.heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func openArticle() { NSWorkspace.shared.open(item.articleURL) }
}

@MainActor
private final class FirestormNewsImageView: NSView {
    private static let cache = NSCache<NSURL, NSImage>()
    private var image: NSImage?
    private var loader: FirestormNewsImageLoader?

    init(url: URL?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.22, alpha: 1).cgColor
        setAccessibilityElement(false)
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return }
        if let cached = Self.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }
        loader = FirestormNewsImageLoader(url: url) { [weak self] decoded in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loader = nil
                guard let decoded else { return }
                let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                Self.cache.setObject(image, forKey: url as NSURL, cost: decoded.width * decoded.height * 4)
                Self.cache.totalCostLimit = 12 * 1024 * 1024
                self.image = image
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { loader?.cancel() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// Image requests have a byte limit and decode only a thumbnail, so an article
/// image cannot allocate a full-resolution bitmap or block the main thread.
private final class FirestormNewsImageLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 4 * 1024 * 1024
    private var data = Data()
    private var session: URLSession!
    private var finished = false
    private let completion: (CGImage?) -> Void

    init(url: URL, completion: @escaping (CGImage?) -> Void) {
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session.dataTask(with: url).resume()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.mimeType?.lowercased().hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count <= Self.maximumBytes - data.count else {
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        defer { session.finishTasksAndInvalidate() }
        guard error == nil, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            completion(nil)
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        completion(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }
}
