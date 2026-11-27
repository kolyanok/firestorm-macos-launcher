import Foundation

private struct WowheadLinksTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic fixes fragments only: link targets are never visited by these tests.
enum WowheadLinksTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            checks += 1
            if try !condition() { throw WowheadLinksTestFailure(description: message) }
        }
        func orderedLinks(_ value: FirestormRichText) throws -> [FirestormTextLink] {
            let links = value.links.sorted { $0.range.location < $1.range.location }
            let length = (value.text as NSString).length
            var previousEnd = 0
            for link in links {
                try expect(link.range.location != NSNotFound && link.range.location >= 0,
                           "Each link has a real nonnegative UTF-16 location")
                try expect(link.range.length > 0 && link.range.location <= length && link.range.length <= length - link.range.location,
                           "Each link range stays within the rendered UTF-16 text")
                try expect(link.range.location >= previousEnd, "Independent clickable spans do not overlap")
                previousEnd = NSMaxRange(link.range)
            }
            return links
        }
        func labels(_ value: FirestormRichText) throws -> [String] {
            try orderedLinks(value).map { link in
                (value.text as NSString).substring(with: link.range)
                    .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        func boldCoverage(_ value: FirestormRichText) throws -> Set<Int> {
            let length = (value.text as NSString).length
            var coverage = Set<Int>()
            for range in value.boldRanges {
                try expect(range.location != NSNotFound && range.location >= 0,
                           "Bold formatting has a real nonnegative UTF-16 location")
                try expect(range.length > 0 && range.location <= length && range.length <= length - range.location,
                           "Bold formatting stays within the rendered UTF-16 text")
                coverage.formUnion(range.location..<NSMaxRange(range))
            }
            return coverage
        }
        func expectBold(_ value: FirestormRichText, _ label: String, _ message: String) throws {
            let range = (value.text as NSString).range(of: label)
            try expect(range.location != NSNotFound, "The expected formatted label remains visible: \(label)")
            let coverage = try boldCoverage(value)
            try expect((range.location..<NSMaxRange(range)).allSatisfy { coverage.contains($0) }, message)
        }
        func expectPlain(_ value: FirestormRichText, _ label: String, _ message: String) throws {
            let range = (value.text as NSString).range(of: label)
            try expect(range.location != NSNotFound, "The expected plain label remains visible: \(label)")
            let coverage = try boldCoverage(value)
            try expect((range.location..<NSMaxRange(range)).allSatisfy { !coverage.contains($0) }, message)
        }

        let basic = FirestormAPI.richBlockText("<p>Before <a href='https://www.wowhead.com/spell=19434'>[Aimed Shot]</a> after.</p>")
        try expect(basic.text == "Before [Aimed Shot] after.", "Inline spell links preserve the visible surrounding sentence")
        try expect(basic.links.count == 1, "One Wowhead anchor creates one clickable span")
        try expect(try labels(basic) == ["[Aimed Shot]"], "The spell label alone is clickable")
        try expect(basic.links.first?.url.absoluteString == "https://www.wowhead.com/spell=19434", "The original spell target is retained")

        let unicodePrefix = "До 👩🏽‍💻 🇷🇺: "
        let unicode = FirestormAPI.richBlockText("<p>\(unicodePrefix)<a href='https://www.wowhead.com/ru/spell=19434'>[Прицельный выстрел]</a> после 🔥.</p>")
        try expect(unicode.text == unicodePrefix + "[Прицельный выстрел] после 🔥.", "Russian text and composed emoji survive rendering")
        try expect(try labels(unicode) == ["[Прицельный выстрел]"], "UTF-16 ranges select the complete Russian label")
        try expect(unicode.links.first?.range.location == unicodePrefix.utf16.count, "Link offsets count UTF-16 units rather than Swift Characters")
        try expect(unicode.links.first?.range.length == "[Прицельный выстрел]".utf16.count, "Link lengths use UTF-16 units")

        let markup = FirestormAPI.richBlockText("<p><a href='https://wowhead.com/spell=1'>[A &amp; <strong>B</strong><span>&nbsp;🔥</span>]</a></p>")
        try expect(markup.text == "[A & B 🔥]", "Entities and nested inline markup produce readable labels")
        try expect(try labels(markup) == ["[A & B 🔥]"], "A range remains correct after entity decoding and nested markup removal")

        let repeated = FirestormAPI.richBlockText("""
            <p><a href="https://wowhead.com/spell=11">Same spell</a>,
            <a href="https://wowhead.com/spell=22"><b>Same spell</b></a>,
            <a href="https://wowhead.com/item=33">Same spell</a>.</p>
            """)
        let repeatedLinks = try orderedLinks(repeated)
        try expect(repeatedLinks.count == 3, "Repeated visible labels remain separate clickable occurrences")
        try expect(try labels(repeated) == ["Same spell", "Same spell", "Same spell"], "All repeated labels map to their own text occurrence")
        try expect(repeatedLinks.map(\.url.absoluteString) == [
            "https://wowhead.com/spell=11", "https://wowhead.com/spell=22", "https://wowhead.com/item=33",
        ], "Repeated labels preserve their distinct targets instead of linking the first match repeatedly")

        let rejectedBeforeValid = FirestormAPI.richBlockText("""
            <p><a href="https://example.com/spell=1">Repeated label</a> then
            <a href="https://wowhead.com/spell=2">Repeated label</a>.</p>
            """)
        try expect(rejectedBeforeValid.links.count == 1, "An unsafe earlier anchor does not create a clickable span")
        try expect(try labels(rejectedBeforeValid) == ["Repeated label"], "A later safe occurrence keeps its own label")
        let lastLabel = (rejectedBeforeValid.text as NSString).range(of: "Repeated label", options: .backwards)
        try expect(rejectedBeforeValid.links.first?.range == lastLabel, "The safe target is applied to the later occurrence, not an earlier identical label")

        let structured = FirestormAPI.richBlockText("""
            <h2>Classes</h2><p>Intro.</p><ul><li>Outer
            <ul><li>Before <a href="https://wowhead.com/spell=42"><span>[Nested spell]</span></a> after.</li></ul>
            </li></ul><p>Final <a href="https://wowhead.com/npc=43">[Creature]</a>.</p>
            """)
        try expect(structured.text.contains("Classes\n") && structured.text.contains("• Outer"), "Headings and list structure remain readable")
        try expect(structured.text.contains("  • Before [Nested spell] after."), "Nested bullets keep indentation before linked text")
        try expect(try labels(structured) == ["[Nested spell]", "[Creature]"], "Bullet prefixes and paragraph separators are excluded from link labels")

        let spaced = FirestormAPI.richBlockText("<p>Before <a href='https://wowhead.com/spell=7'> \n <b>Aimed</b>\t Shot \n </a> after.</p>")
        try expect(spaced.text.contains("Aimed Shot") && !spaced.text.contains("\t"), "Anchor whitespace is normalized along with the displayed sentence")
        try expect(try labels(spaced) == ["Aimed Shot"], "Leading and trailing anchor whitespace does not offset the visible clickable words")

        let multiline = FirestormAPI.richBlockText("<p><a href='https://wowhead.com/spell=8'>First line<br>Second <b>line</b></a></p>")
        let multilineLabels = try labels(multiline)
        try expect(multiline.text.contains("First line\nSecond line"), "An explicit line break inside a link stays visible")
        try expect(multilineLabels.joined(separator: " ").contains("First line") && multilineLabels.joined(separator: " ").contains("Second line"),
                   "A multiline anchor retains clickable words on both sides of the line break")
        try expect(multiline.links.allSatisfy { $0.url.absoluteString == "https://wowhead.com/spell=8" }, "Segments of a multiline anchor retain one target")

        // Foundation's HTML4 recovery may close a block-level HTML5 anchor.
        // Keep its text readable and any surviving spans safe; the official
        // fixes source uses inline spell/item links instead of block anchors.
        let blockAnchor = FirestormAPI.richBlockText("<a href='https://wowhead.com/item=9'><p>First block</p><p>Second block</p></a>")
        try expect(blockAnchor.text.contains("First block") && blockAnchor.text.contains("Second block"), "HTML recovery preserves block-anchor text")
        let blockLinks = try orderedLinks(blockAnchor)
        try expect(blockLinks.allSatisfy { $0.url.absoluteString == "https://wowhead.com/item=9" }, "HTML recovery cannot invent a different block-anchor target")

        let safeTargets = [
            "https://wowhead.com/spell=1",
            "https://www.wowhead.com/ru/spell=2",
            "https://ptr.wowhead.com/spell=3",
            "https://classic.wowhead.com/item=4",
            "https://wowhead.com:443/npc=5",
        ]
        for target in safeTargets {
            let rich = FirestormAPI.richBlockText("<p><a href='\(target)'>Safe target</a></p>")
            try expect(rich.links.count == 1, "Official Wowhead hosts remain clickable: \(target)")
            try expect(try labels(rich) == ["Safe target"], "A permitted target retains its exact label")
            try expect(rich.links[0].url.scheme?.lowercased() == "https", "Clickable targets use HTTPS")
        }
        for target in ["http://www.wowhead.com/spell=11", "//www.wowhead.com/ru/spell=12"] {
            let rich = FirestormAPI.richBlockText("<p><a href='\(target)'>Upgrade</a></p>")
            try expect(rich.links.count == 1 && rich.links[0].url.scheme == "https", "Legacy/protocol-relative Wowhead targets upgrade to HTTPS")
            try expect(try labels(rich) == ["Upgrade"], "Upgrading the URL does not change the clickable label")
        }
        let query = FirestormAPI.richBlockText("<a href='https://www.wowhead.com/spell=19434?level=90&amp;class=3#comments'>[Query spell]</a>")
        try expect(query.links.count == 1, "A Wowhead target with query and fragment stays clickable")
        let queryURL = query.links.first?.url
        try expect(queryURL?.absoluteString == "https://www.wowhead.com/spell=19434?level=90&class=3#comments", "HTML entities in href decode without losing query parameters or fragments")

        let unsafeTargets = [
            "javascript:alert(1)", "data:text/html,example", "file:///tmp/private", "mailto:someone@wowhead.com",
            "https://example.com/spell=1", "https://wowhead.com.evil.example/spell=1",
            "https://evilwowhead.com/spell=1", "https://wowhead.com@evil.example/spell=1",
            "https://user:password@wowhead.com/spell=1", "https://wowhead.com:8080/spell=1",
            "http://wowhead.com:80/spell=1", "/spell=1", "#local",
        ]
        for target in unsafeTargets {
            let rich = FirestormAPI.richBlockText("<p><a href='\(target)'>Readable label</a></p>")
            try expect(rich.text.contains("Readable label"), "An unsupported target does not remove the visible fixes text")
            try expect(rich.links.isEmpty, "Unsupported schemes, hosts, credentials and ports never become clickable: \(target)")
        }
        let noCode = FirestormAPI.richBlockText("""
            <script><a href="https://wowhead.com/spell=1">Hidden script link</a></script>
            <style><a href="https://wowhead.com/spell=2">Hidden style link</a></style>
            <p>Visible <a href="https://wowhead.com/spell=3">Safe spell</a></p>
            """)
        try expect(!noCode.text.contains("Hidden script") && !noCode.text.contains("Hidden style"), "Script and style content remains excluded")
        try expect(try labels(noCode) == ["Safe spell"], "Ignored code cannot inject phantom clickable ranges")

        let targetA = FirestormAPI.richBlockText("<p><a href='https://wowhead.com/spell=1'>Same text</a></p>")
        let targetB = FirestormAPI.richBlockText("<p><a href='https://wowhead.com/spell=2'>Same text</a></p>")
        try expect(targetA.text == targetB.text && targetA.links != targetB.links, "A target-only change is observable even when the text remains unchanged")
        try expect(FirestormAPI.blockText("<p>No <b>links</b> here.</p>") == FirestormAPI.richBlockText("<p>No <b>links</b> here.</p>").text,
                   "The existing plain-text entry point retains the rich renderer's text")

        // The captured official fixes use <p><strong> for section labels and
        // <li><strong> for class names. Test that actual structure rather than
        // assuming those labels arrive as HTML heading elements.
        let originalStructure = FirestormAPI.richBlockText("""
            <p><strong>Classes</strong></p><ul><li><strong>Hunter</strong><ul>
            <li>Correct behavior. <a href="https://wowhead.com/spell=19434">[Aimed Shot]</a></li>
            </ul></li></ul><p>Ordinary paragraph.</p>
            """)
        try expectBold(originalStructure, "Classes", "Official section labels retain bold formatting")
        try expectBold(originalStructure, "Hunter", "Official class labels retain bold formatting")
        try expectPlain(originalStructure, "Correct behavior.", "Class-label bold does not leak into nested correction text")
        try expectPlain(originalStructure, "Ordinary paragraph.", "Bold formatting ends with its source element")
        try expectPlain(originalStructure, "[Aimed Shot]", "A link without bold markup does not become bold merely because its parent class label was bold")
        try expect(try labels(originalStructure) == ["[Aimed Shot]"], "Restoring class and section formatting preserves existing clickable spells")
        let classBullet = (originalStructure.text as NSString).range(of: "• Hunter").location
        try expect(classBullet != NSNotFound, "The formatted class label still has its list marker")
        try expect(try !boldCoverage(originalStructure).contains(classBullet), "Generated list markers do not accidentally inherit a class label's bold range")

        for level in 1...6 {
            let heading = FirestormAPI.richBlockText("<h\(level)>Heading \(level)</h\(level)><p>Plain body.</p>")
            try expectBold(heading, "Heading \(level)", "Semantic heading h\(level) is rendered bold")
            try expectPlain(heading, "Plain body.", "Heading formatting does not extend into the following paragraph")
        }
        let nestedBold = FirestormAPI.richBlockText("<p>Before <b>Bold <span>nested <strong>and strong</strong></span></b> after.</p>")
        try expect(nestedBold.text == "Before Bold nested and strong after.", "Nested formatting neither duplicates nor removes visible words")
        try expectBold(nestedBold, "Bold nested and strong", "Nested inline tags preserve inherited bold formatting")
        try expectPlain(nestedBold, "Before", "Text before a bold run keeps its normal weight")
        try expectPlain(nestedBold, "after.", "Text after a nested bold run keeps its normal weight")

        let unicodeBoldPrefix = "До 👩🏽‍💻: "
        let linkedBold = FirestormAPI.richBlockText("<p>\(unicodeBoldPrefix)<strong><a href='https://wowhead.com/ru/spell=19434'>[Прицельный 🔥 выстрел]</a></strong> после.</p>")
        try expectBold(linkedBold, "[Прицельный 🔥 выстрел]", "Bold ranges use complete UTF-16 spans for Russian and emoji")
        try expect(try labels(linkedBold) == ["[Прицельный 🔥 выстрел]"], "A bold spell remains clickable across the same Unicode text")
        try expect(linkedBold.links.first?.range.location == unicodeBoldPrefix.utf16.count, "Bold metadata does not move a Unicode link's existing UTF-16 offset")
        try expectPlain(linkedBold, "после.", "Combined link and bold formatting ends before the sentence continuation")
        let boldInsideLink = FirestormAPI.richBlockText("<p><a href='https://wowhead.com/item=123'>Normal <b>bold words</b> normal</a></p>")
        try expect(try labels(boldInsideLink) == ["Normal bold words normal"], "A link can span both normal and bold inline words")
        try expectBold(boldInsideLink, "bold words", "Bold markup nested within a link is retained")
        try expectPlain(boldInsideLink, "Normal", "Partial bold formatting does not turn the whole anchor bold")

        let repeatedBold = FirestormAPI.richBlockText("<p>Same label then <strong>Same label</strong>.</p>")
        let firstRepeated = (repeatedBold.text as NSString).range(of: "Same label")
        let lastRepeated = (repeatedBold.text as NSString).range(of: "Same label", options: .backwards)
        let repeatedCoverage = try boldCoverage(repeatedBold)
        try expect((firstRepeated.location..<NSMaxRange(firstRepeated)).allSatisfy { !repeatedCoverage.contains($0) }, "An earlier identical label is not bolded by matching its text")
        try expect((lastRepeated.location..<NSMaxRange(lastRepeated)).allSatisfy { repeatedCoverage.contains($0) }, "Bold metadata belongs to its own source occurrence")

        let excludedBold = FirestormAPI.richBlockText("<script><strong>Hidden code</strong></script><style><b>Hidden style</b></style><p>Visible <strong>safe bold</strong>.</p>")
        try expect(!excludedBold.text.contains("Hidden code") && !excludedBold.text.contains("Hidden style"), "Excluded script/style text cannot introduce visible bold runs")
        try expectBold(excludedBold, "safe bold", "Visible formatting remains after excluded code is removed")
        let unchangedStyleText = FirestormAPI.richBlockText("<p>Stable label</p>")
        let changedStyle = FirestormAPI.richBlockText("<p><strong>Stable label</strong></p>")
        try expect(unchangedStyleText.text == changedStyle.text && unchangedStyleText.links == changedStyle.links && unchangedStyleText.boldRanges != changedStyle.boldRanges,
                   "A formatting-only change remains observable even when text and links stay identical")

        let longTail = String(repeating: "A detailed fix stays visible. ", count: 30) + "END OF PATCH"
        let row: [String: Any] = [
            "ID": 901, "Date": "1795734053", "CategoryID": 2, "SubCategoryID": 34, "Visible": 1, "HideFromHomepage": 1,
            "Title": ["0": ["Locale": 0, "Value": "Fixes"], "4": ["Locale": 4, "Value": "Исправления"]],
            "Content": [
                "0": ["Locale": 0, "Value": "<p><strong>Classes</strong></p><p>Read <a href='https://wowhead.com/spell=19434'><strong>[Aimed Shot]</strong></a>.</p><p>\(longTail)</p>"],
                "4": ["Locale": 4, "Value": "<p><strong>Классы</strong></p><p>Читайте <a href='https://wowhead.com/ru/spell=19434'><strong>[Прицельный выстрел]</strong></a>.</p><p>\(longTail)</p>"],
            ],
        ]
        let response = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "result": ["ErrorID": 0, "News": [row]], "id": 1])
        for (language, expectedLabel, expectedURL) in [
            ("en", "[Aimed Shot]", "https://wowhead.com/spell=19434"),
            ("ru", "[Прицельный выстрел]", "https://wowhead.com/ru/spell=19434"),
        ] {
            let items = try FirestormFixesService.decodeAPI(response, language: language)
            try expect(items.count == 1, "The localized fixes decoder retains a linked article")
            let item = items[0]
            let rich = FirestormRichText(text: item.bodyText, links: item.bodyLinks, boldRanges: item.bodyBoldRanges)
            try expect(try labels(rich) == [expectedLabel], "Fixes decoding retains localized link labels and UTF-16 ranges")
            try expect(item.bodyLinks.first?.url.absoluteString == expectedURL, "Fixes decoding retains the matching localized Wowhead target")
            try expectBold(rich, language == "ru" ? "Классы" : "Classes", "Fixes decoding preserves the localized section-heading bold metadata")
            try expectBold(rich, expectedLabel, "Fixes decoding preserves overlapping bold and link ranges")
            try expect(item.bodyText.count > 800 && item.bodyText.hasSuffix("END OF PATCH"), "Adding links does not truncate the complete fixes body")
        }
        return checks
    }
}
