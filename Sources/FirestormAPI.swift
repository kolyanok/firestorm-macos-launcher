import Foundation
import CoreFoundation

struct FirestormTextLink: Equatable {
    let range: NSRange
    let url: URL
}

struct FirestormRichText: Equatable {
    let text: String
    let links: [FirestormTextLink]
    let boldRanges: [NSRange]

    init(text: String, links: [FirestormTextLink], boldRanges: [NSRange] = []) {
        self.text = text
        self.links = links
        self.boldRanges = boldRanges
    }
}

/// Public launcher RPC transport shared by news, fixes and realm information.
/// This application identifier ships in Firestorm's public launcher installer;
/// no player account, session cookie or password is attached to these requests.
enum FirestormAPI {
    enum Failure: Error {
        case invalidResponse
        case api(Int)
    }

    private static let clientIdentifier = "a37d3e34e3eeeaea9f440ade4cd28d8d6f23fcb4"

    static func makeRequest(method: String, parameters: [Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.firestorm-servers.com/cgi-bin/processACT")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Firestorm/2.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method, "id": 1,
            "params": [clientIdentifier] + parameters
        ])
        return request
    }

    static func decodeResult(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        if let error = root["error"], !(error is NSNull) {
            throw Failure.api(integer((error as? [String: Any])?["ErrorID"]) ?? -1)
        }
        guard let result = root["result"] as? [String: Any],
              let status = integer(result["ErrorID"]) else { throw Failure.invalidResponse }
        guard status == 0 else { throw Failure.api(status) }
        return result
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? String { return Int(value) }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            guard number.isFinite, number.rounded() == number,
                  number >= Double(Int.min), number < Double(Int.max) else { return nil }
            return value.intValue
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? String { return Double(value) }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.doubleValue
        }
        return nil
    }

    static func flag(_ value: Any?, default fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = integer(value) { return value != 0 }
        return fallback
    }

    /// Localized API fields are arrays or dictionaries containing Locale/Value
    /// records. Match the requested locale, then English, then any usable value.
    static func localized(_ value: Any?, localeID: Int) -> String? {
        let entries: [[String: Any]]
        if let values = value as? [[String: Any]] { entries = values }
        else if let values = value as? [String: Any] {
            entries = values.keys.sorted().compactMap { values[$0] as? [String: Any] }
        } else { return nil }
        func text(_ entry: [String: Any]) -> String? {
            guard let value = entry["Value"] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        return entries.first(where: { integer($0["Locale"]) == localeID && text($0) != nil }).flatMap(text)
            ?? entries.first(where: { integer($0["Locale"]) == 0 && text($0) != nil }).flatMap(text)
            ?? entries.compactMap(text).first
    }

    static func plainText(_ html: String) -> String {
        guard let body = htmlBody(html),
              let nodes = try? body.nodes(forXPath: ".//text()[not(ancestor::script) and not(ancestor::style) and not(ancestor::noscript) and not(ancestor::template)]") else {
            return fallbackText(html)
        }
        return normalize(nodes.compactMap(\.stringValue).joined())
    }

    /// Converts HTML into native text while retaining full patch-note structure.
    static func blockText(_ html: String) -> String {
        richBlockText(html).text
    }

    /// Links are recorded while building the final text, rather than searched by
    /// label afterwards. Ranges use UTF-16, matching NSTextStorage/NSAttributedString.
    static func richBlockText(_ html: String) -> FirestormRichText {
        guard let body = htmlBody(html) else {
            return FirestormRichText(text: fallbackText(html), links: [])
        }
        var builder = BlockTextBuilder()
        builder.visit(body)
        return builder.result()
    }

    /// Preserve the original Wowhead target and locale, but allow navigation only
    /// to its HTTPS domains. This is also used when a native link is clicked.
    static func wowheadURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if candidate.hasPrefix("//") { candidate = "https:" + candidate }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              host == "wowhead.com" || host.hasSuffix(".wowhead.com"),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        components.scheme = "https"
        components.host = host
        return components.url
    }

    private static func htmlBody(_ html: String) -> XMLNode? {
        let wrapped = "<html><body><div>\(html)</div></body></html>"
        guard let document = try? XMLDocument(xmlString: wrapped, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let body = try? document.nodes(forXPath: "//body").first else { return nil }
        return body
    }

    private static func normalize(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func fallbackText(_ html: String) -> String {
        let withoutCode = html.replacingOccurrences(of: #"(?is)<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        return normalize(withoutCode.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression))
    }

    private struct BlockTextBuilder {
        private struct Line {
            let text: String
            let links: [FirestormTextLink]
            let boldRanges: [NSRange]
        }

        private var lines: [Line] = []
        private var text = ""
        private var textLength = 0
        private var textLinks: [FirestormTextLink] = []
        private var textBoldRanges: [NSRange] = []
        private var prefix = ""
        private var continuationPrefix = ""
        private var pendingMarker: String?

        mutating func visit(_ node: XMLNode, listDepth: Int = 0, link: URL? = nil, bold: Bool = false) {
            if node.kind == .text {
                append(node.stringValue ?? "", link: link, bold: bold)
                return
            }
            guard node.kind == .element || node.kind == .document else { return }
            let name = node.name?.lowercased() ?? ""
            guard !["script", "style", "noscript", "template"].contains(name) else { return }
            let currentLink = name == "a"
                ? FirestormAPI.wowheadURL((node as? XMLElement)?.attribute(forName: "href")?.stringValue)
                : link
            let currentBold = bold || ["b", "strong", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
            if name == "br" { flush(); return }
            if name == "ul" || name == "ol" {
                flush()
                let savedPrefix = prefix
                let savedContinuation = continuationPrefix
                let savedMarker = pendingMarker
                var number = 1
                for child in node.children ?? [] where child.name?.lowercased() == "li" {
                    prefix = String(repeating: "  ", count: listDepth)
                    continuationPrefix = prefix + "  "
                    pendingMarker = name == "ol" ? "\(number). " : "• "
                    for itemChild in child.children ?? [] { visit(itemChild, listDepth: listDepth + 1, link: currentLink, bold: currentBold) }
                    flush()
                    pendingMarker = nil
                    number += 1
                }
                prefix = savedPrefix
                continuationPrefix = savedContinuation
                pendingMarker = savedMarker
                if listDepth == 0 { blankLine() }
                return
            }
            let block = ["p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"].contains(name)
            if block { flush(); blankLine() }
            if name == "tr" { flush() }
            for child in node.children ?? [] { visit(child, listDepth: listDepth, link: currentLink, bold: currentBold) }
            if name == "td" || name == "th" { append(" | ") }
            if name == "tr" { flush() }
            if block { flush(); blankLine() }
        }

        private mutating func append(_ value: String, link: URL? = nil, bold: Bool = false) {
            let normalized = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if !text.isEmpty && !text.hasSuffix(" ") { appendText(" ", link: link, bold: bold) }
                return
            }
            if let marker = pendingMarker {
                appendText(marker, link: nil, bold: false)
                pendingMarker = nil
            }
            appendText(normalized, link: link, bold: bold)
        }

        private mutating func appendText(_ value: String, link: URL?, bold: Bool) {
            let length = value.utf16.count
            if bold, length > 0 {
                if let previous = textBoldRanges.last, NSMaxRange(previous) == textLength {
                    textBoldRanges[textBoldRanges.count - 1] = NSRange(location: previous.location, length: previous.length + length)
                } else {
                    textBoldRanges.append(NSRange(location: textLength, length: length))
                }
            }
            if let link, length > 0 {
                let range = NSRange(location: textLength, length: length)
                if let previous = textLinks.last,
                   previous.url == link, NSMaxRange(previous.range) == range.location {
                    textLinks[textLinks.count - 1] = FirestormTextLink(
                        range: NSRange(location: previous.range.location, length: previous.range.length + length), url: link)
                } else {
                    textLinks.append(FirestormTextLink(range: range, url: link))
                }
            }
            text += value
            textLength += length
        }

        private mutating func flush() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                let leadingTrim = text.prefix(while: { $0.isWhitespace }).utf16.count
                let visible = NSRange(location: leadingTrim, length: value.utf16.count)
                let prefixLength = prefix.utf16.count
                let links = textLinks.compactMap { link -> FirestormTextLink? in
                    let overlap = NSIntersectionRange(link.range, visible)
                    guard overlap.length > 0 else { return nil }
                    return FirestormTextLink(
                        range: NSRange(location: prefixLength + overlap.location - leadingTrim, length: overlap.length), url: link.url)
                }
                let boldRanges = textBoldRanges.compactMap { range -> NSRange? in
                    let overlap = NSIntersectionRange(range, visible)
                    guard overlap.length > 0 else { return nil }
                    return NSRange(location: prefixLength + overlap.location - leadingTrim, length: overlap.length)
                }
                lines.append(Line(text: prefix + value, links: links, boldRanges: boldRanges))
                prefix = continuationPrefix
            }
            text = ""
            textLength = 0
            textLinks.removeAll(keepingCapacity: true)
            textBoldRanges.removeAll(keepingCapacity: true)
        }

        private mutating func blankLine() {
            if let last = lines.last, !last.text.isEmpty { lines.append(Line(text: "", links: [], boldRanges: [])) }
        }

        mutating func result() -> FirestormRichText {
            flush()
            while lines.last?.text == "" { lines.removeLast() }
            var links: [FirestormTextLink] = []
            var boldRanges: [NSRange] = []
            var offset = 0
            for line in lines {
                links += line.links.map {
                    FirestormTextLink(range: NSRange(location: offset + $0.range.location, length: $0.range.length), url: $0.url)
                }
                boldRanges += line.boldRanges.map { NSRange(location: offset + $0.location, length: $0.length) }
                offset += line.text.utf16.count + 1
            }
            return FirestormRichText(text: lines.map(\.text).joined(separator: "\n"), links: links, boldRanges: boldRanges)
        }
    }
}
