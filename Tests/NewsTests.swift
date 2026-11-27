import Foundation

private struct NewsTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic launcher JSON-RPC responses only. These checks perform no network
/// calls and never include an account or the official launcher's client ID.
enum NewsTests {
    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw NewsTestFailure(description: message) }
        }
        func rejects(_ data: Data, _ message: String) throws {
            do {
                _ = try FirestormNewsService.decodeAPI(data, language: "en")
            } catch {
                checks += 1
                return
            }
            throw NewsTestFailure(description: message)
        }

        let localized = row(622, english: "Midnight is live", russian: "Миднайт уже доступен")
        let english = try FirestormNewsService.decodeAPI(envelope([localized]), language: "en")
        let russian = try FirestormNewsService.decodeAPI(envelope([localized]), language: "ru")
        try expect(english.count == 1 && russian.count == 1, "Both interface languages decode the same public feed shape")
        try expect(english[0].title == "Midnight is live", "English chooses locale 0")
        try expect(russian[0].title == "Миднайт уже доступен", "Russian chooses locale 4 without corrupting UTF-8")
        try expect(english[0].articleURL.absoluteString == "https://firestorm-servers.com/en/news/622", "English article links use the official localized URL")
        try expect(russian[0].articleURL.absoluteString == "https://firestorm-servers.com/ru/news/622", "Russian article links use the official localized URL")
        try expect(english[0].publishedAt?.timeIntervalSince1970 == 1795024285, "String Unix timestamps retain their UTC instant")
        try expect(english[0].imageURL?.absoluteString == "https://firestorm-servers.com/assets/img/news/622.png", "Picture filenames resolve beneath the official HTTPS news directory")

        var noRussian = localized
        noRussian["Title"] = ["0": ["Locale": 0, "Value": "English fallback"]]
        let fallbackEnglish = try FirestormNewsService.decodeAPI(envelope([noRussian]), language: "ru")
        try expect(fallbackEnglish[0].title == "English fallback", "An unavailable Russian title falls back to English")
        var onlyFrench = localized
        onlyFrench["Title"] = ["1": ["Locale": 1, "Value": "Titre disponible"]]
        let fallbackFirst = try FirestormNewsService.decodeAPI(envelope([onlyFrench]), language: "en")
        try expect(fallbackFirst[0].title == "Titre disponible", "A title still displays when only another translation exists")
        var emptyRussian = localized
        emptyRussian["Title"] = ["0": ["Locale": 0, "Value": "Nonempty fallback"], "4": ["Locale": 4, "Value": "  \n "]]
        let fallbackEmpty = try FirestormNewsService.decodeAPI(envelope([emptyRussian]), language: "ru")
        try expect(fallbackEmpty[0].title == "Nonempty fallback", "An empty requested translation does not hide a usable fallback")
        var arrayTranslations = localized
        arrayTranslations["Title"] = [["Locale": 0, "Value": "Array English"], ["Locale": 4, "Value": "Перевод из массива"]]
        let translatedArray = try FirestormNewsService.decodeAPI(envelope([arrayTranslations]), language: "ru")
        try expect(translatedArray[0].title == "Перевод из массива", "Locale collections tolerate JSON arrays as well as keyed objects")

        let entities = row(623, english: "  <strong>A &amp; B</strong>&nbsp; &#x2014; &quot;news&quot;  ", russian: "<b>Мир</b> &amp; друзья &#128293;")
        let plainEnglish = try FirestormNewsService.decodeAPI(envelope([entities]), language: "en")[0]
        let plainRussian = try FirestormNewsService.decodeAPI(envelope([entities]), language: "ru")[0]
        try expect(plainEnglish.title == "A & B — \"news\"", "Title HTML becomes normalized plain text with decoded entities")
        try expect(plainRussian.title == "Мир & друзья 🔥", "Russian titles preserve numeric emoji and text after markup removal")
        var script = row(624, english: "Visible<script>hiddenScript()</script><style>.hidden{}</style> headline")
        script["Content"] = ["0": ["Locale": 0, "Value": "<p>Safe &amp; readable</p><script>doNotRun()</script>"]]
        let stripped = try FirestormNewsService.decodeAPI(envelope([script]), language: "en")[0]
        try expect(!stripped.title.contains("hiddenScript") && !stripped.title.contains(".hidden"), "Script and style text are excluded from the displayed title")
        try expect(stripped.summary?.contains("doNotRun") != true, "Script text does not leak into the optional summary")

        var hidden = row(625, english: "Hidden from homepage")
        hidden["HideFromHomepage"] = 1
        var unpublished = row(626, english: "Unpublished")
        unpublished["Visible"] = 0
        var wrongCategory = row(627, english: "Other category")
        wrongCategory["CategoryID"] = 2
        var visibleWithoutFlag = row(628, english: "Missing optional visibility")
        visibleWithoutFlag.removeValue(forKey: "Visible")
        let filtered = try FirestormNewsService.decodeAPI(envelope([hidden, unpublished, wrongCategory, visibleWithoutFlag, localized]), language: "en")
        try expect(filtered.map(\.id) == ["628", "622"], "Homepage/category/visibility filtering preserves valid source order")
        var hiddenBoolean = row(629, english: "Boolean hidden flag")
        hiddenBoolean["HideFromHomepage"] = true
        let hiddenBooleanResult = try FirestormNewsService.decodeAPI(envelope([hiddenBoolean, localized]), language: "en")
        try expect(hiddenBooleanResult.map(\.id) == ["622"], "Truthy boolean homepage flags are filtered")

        var noTitle = row(630, english: "")
        noTitle["Title"] = NSNull()
        var replacement = row(630, english: "Valid replacement")
        replacement["Date"] = 1795024285
        let mixed: [Any] = [
            "not an article", NSNull(), 17,
            row(0, english: "Zero ID"), row(-1, english: "Negative ID"),
            row(630.5, english: "Fractional ID"), row(true, english: "Boolean ID"),
            row("../630", english: "Path ID"), noTitle,
            replacement, row(630, english: "Duplicate replacement"),
            row(631, english: "Final sibling"),
        ]
        let validSiblings = try FirestormNewsService.decodeAPI(envelope(mixed), language: "en")
        try expect(validSiblings.map(\.id) == ["630", "631"], "Malformed entries and duplicate IDs do not hide valid siblings")
        try expect(validSiblings[0].title == "Valid replacement", "Malformed rows must not reserve the ID before a valid title is found")
        try expect(validSiblings[0].publishedAt?.timeIntervalSince1970 == 1795024285, "Numeric Unix timestamps are accepted")
        var badOptionalFields = row(632, english: "Still readable")
        badOptionalFields["Date"] = "not a timestamp"
        badOptionalFields["Picture"] = "../private.png"
        badOptionalFields["PictureAlt"] = ""
        let optionalFailure = try FirestormNewsService.decodeAPI(envelope([badOptionalFields]), language: "en")[0]
        try expect(optionalFailure.publishedAt == nil && optionalFailure.imageURL == nil, "Invalid optional date/image does not discard article text")
        var alternate = row(633, english: "Alternate image")
        alternate["Picture"] = ""
        alternate["PictureAlt"] = "alternate.png"
        let alternateImage = try FirestormNewsService.decodeAPI(envelope([alternate]), language: "en")[0]
        try expect(alternateImage.imageURL?.absoluteString == "https://firestorm-servers.com/assets/img/news/alternate.png", "Missing Picture falls back to PictureAlt")

        let empty = try FirestormNewsService.decodeAPI(envelope([]), language: "en")
        try expect(empty.isEmpty, "An empty successful API feed produces the empty state")
        try rejects(envelope([localized], errorID: 5), "Nonzero API ErrorID must surface as a failure")
        try rejects(json(["jsonrpc": "2.0", "error": ["code": -32603, "message": "Internal error"], "id": 1]), "JSON-RPC errors must not look like empty news")
        try rejects(json(["jsonrpc": "2.0", "result": ["ErrorID": 0, "News": "unexpected"], "id": 1]), "A changed nonarray News field must be rejected")
        try rejects(json(["jsonrpc": "2.0", "result": NSNull(), "id": 1]), "A null result must be rejected")
        try rejects(Data("{broken json".utf8), "Malformed JSON must be rejected")
        try rejects(Data("<html>Checking your browser</html>".utf8), "An HTML challenge must not be accepted as a feed")

        let acceptedImages: [(String, String)] = [
            ("/assets/img/news/622.jpg", "https://firestorm-servers.com/assets/img/news/622.jpg"),
            ("http://firestorm-servers.com/assets/img/news/622.jpg", "https://firestorm-servers.com/assets/img/news/622.jpg"),
            ("https://www.firestorm-servers.com/assets/img/news/622.jpg", "https://www.firestorm-servers.com/assets/img/news/622.jpg"),
        ]
        for (raw, expected) in acceptedImages {
            try expect(FirestormNewsService.safeImageURL(raw)?.absoluteString == expected, "Official image URL should resolve safely: \(raw)")
        }
        for raw in [
            "https://example.invalid/image.jpg", "https://firestorm-servers.com.example.invalid/image.jpg",
            "https://firestorm-servers.com@evil.invalid/image.jpg", "https://user:password@firestorm-servers.com/assets/img/news/image.jpg",
            "https://firestorm-servers.com:8443/assets/img/news/image.jpg",
            "https://firestorm-servers.com/assets/img/news/../private.jpg",
            "https://firestorm-servers.com/assets/img/news/%2e%2e/private.jpg",
            "file:///tmp/news-image.png", "javascript:alert(1)", "data:image/png;base64,AAAA", "",
        ] {
            try expect(FirestormNewsService.safeImageURL(raw) == nil, "Untrusted image URL should be rejected: \(raw)")
        }
        try expect(FirestormNewsService.safeImageURL(nil) == nil, "A missing image is optional")

        for (language, expectedLocale) in [("en", 0), ("ru", 4), ("unexpected", 0)] {
            let request = FirestormNewsService.makeRequest(language: language)
            try expect(request.url?.absoluteString == "https://api.firestorm-servers.com/cgi-bin/processACT", "News requests use the original launcher's HTTPS endpoint")
            try expect(request.httpMethod == "POST", "The launcher news RPC uses POST")
            try expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true, "The RPC request declares a JSON body")
            guard let body = request.httpBody,
                  let rpc = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let parameters = rpc["params"] as? [Any] else {
                throw NewsTestFailure(description: "The RPC request must contain JSON params")
            }
            try expect(rpc["method"] as? String == "GetLauncherLastNews", "The request calls the discovered public launcher-news method")
            try expect(parameters.count == 4, "The news RPC has the original four-parameter shape")
            guard parameters.count == 4 else { throw NewsTestFailure(description: "Unexpected params count") }
            let clientID = parameters[0] as? String ?? ""
            try expect(clientID.count == 40 && clientID.allSatisfy { $0.isASCII && $0.isHexDigit }, "The public launcher client context has the expected digest shape")
            try expect((parameters[1] as? NSNumber)?.intValue == 30, "The request limits news to 30 items")
            try expect((parameters[2] as? NSNumber)?.intValue == expectedLocale, "The RPC locale matches the interface language")
            try expect(parameters[3] as? String == "", "Public news requests carry no account token")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Reading news does not attach account authorization")
        }
        return checks
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private static func envelope(_ news: [Any], errorID: Int = 0) -> Data {
        json(["jsonrpc": "2.0", "result": ["ErrorID": errorID, "News": news], "id": 1])
    }

    private static func row(_ id: Any, english: String, russian: String? = nil) -> [String: Any] {
        var titles: [String: Any] = ["0": ["Locale": 0, "Value": english]]
        if let russian { titles["4"] = ["Locale": 4, "Value": russian] }
        return [
            "ID": id, "Date": "1795024285", "CategoryID": 1, "Visible": 1, "HideFromHomepage": 0,
            "Picture": "\(id).png", "PictureAlt": "", "Title": titles,
            "Content": ["0": ["Locale": 0, "Value": "<p>Explore Azeroth &amp; beyond.</p>"]],
        ]
    }
}
