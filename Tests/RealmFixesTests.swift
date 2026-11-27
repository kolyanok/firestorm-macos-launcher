import Foundation

private struct RealmFixesTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic public API fixtures. These checks make no network requests and
/// contain neither account credentials nor the launcher's public client ID.
enum RealmFixesTests {
    static func run() throws -> Int {
        var checks = 0
        let now = Date(timeIntervalSince1970: 1000)
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() { throw RealmFixesTestFailure(description: message) }
        }
        func rejectsRealm(_ data: Data, _ message: String) throws {
            do { _ = try FirestormRealmService.decodeAPI(data, now: now) }
            catch { checks += 1; return }
            throw RealmFixesTestFailure(description: message)
        }
        func rejectsFixes(_ data: Data, _ message: String) throws {
            do { _ = try FirestormFixesService.decodeAPI(data, language: "en") }
            catch { checks += 1; return }
            throw RealmFixesTestFailure(description: message)
        }

        // Realm availability comes from its heartbeat, independently of the
        // player count. Never display a global total as Silvermoon's count.
        let silvermoon = realmRow()
        let realm = try FirestormRealmService.decodeAPI(realmEnvelope([
            realmRow(id: 1, name: "Other realm", online: 99999), silvermoon,
        ]), now: now)
        try expect(realm.name == "Silvermoon", "Realm status selects Silvermoon ID 14")
        try expect(realm.isOnline, "A current heartbeat reports the realm online")
        try expect(realm.playersOnline == 4058, "Player count belongs to the selected realm only")
        try expect(realm.updatedAt?.timeIntervalSince1970 == 1000, "The displayed update time is the realm heartbeat")
        try expect(!realm.isLocked, "Security level zero is publicly accessible")

        let zeroPlayers = try FirestormRealmService.decodeAPI(realmEnvelope([realmRow(online: 0)]), now: now)
        try expect(zeroPlayers.isOnline && zeroPlayers.playersOnline == 0, "A fresh realm with zero players remains online")
        let stalePlayers = try FirestormRealmService.decodeAPI(realmEnvelope([realmRow(online: 4058, updated: 849)]), now: now)
        try expect(!stalePlayers.isOnline, "Positive player count cannot turn a stale heartbeat into online status")
        try expect(stalePlayers.playersOnline == 4058, "A stale heartbeat does not falsify the separately reported player count")
        let boundary = try FirestormRealmService.decodeAPI(realmEnvelope([realmRow(updated: 850)]), now: now)
        try expect(boundary.isOnline, "The heartbeat is fresh at the inclusive 150-second boundary")
        let epoch = try FirestormRealmService.decodeAPI(realmEnvelope([realmRow(updated: 0)]), now: now)
        try expect(!epoch.isOnline, "A zero heartbeat is a known offline value")
        let locked = try FirestormRealmService.decodeAPI(realmEnvelope([realmRow(security: 1)]), now: now)
        try expect(locked.isLocked, "A positive allowed security level marks the realm locked")

        var stringFields = silvermoon
        stringFields["ID"] = "14"
        stringFields["Online"] = "4058"
        stringFields["Lastupdate"] = "1000"
        stringFields["AllowedSecurityLevel"] = "0"
        let stringRealm = try FirestormRealmService.decodeAPI(realmEnvelope([stringFields]), now: now)
        try expect(stringRealm.isOnline && stringRealm.playersOnline == 4058, "String numeric fields from the public API remain usable")

        var missingCount = silvermoon
        missingCount.removeValue(forKey: "Online")
        let countAbsent = try FirestormRealmService.decodeAPI(realmEnvelope([missingCount]), now: now)
        try expect(countAbsent.isOnline && countAbsent.playersOnline == nil, "An absent count is unknown rather than a fabricated zero")
        for invalidCount: Any in [-1, "unknown", NSNull(), true, 4.5] {
            var row = silvermoon
            row["Online"] = invalidCount
            let status = try FirestormRealmService.decodeAPI(realmEnvelope([row]), now: now)
            try expect(status.playersOnline == nil, "An invalid count remains unknown: \(invalidCount)")
            try expect(status.isOnline, "An invalid player count does not override a fresh heartbeat")
        }
        var missingHeartbeat = silvermoon
        missingHeartbeat.removeValue(forKey: "Lastupdate")
        try rejectsRealm(realmEnvelope([missingHeartbeat]), "A missing heartbeat must surface as unknown, not offline")
        for invalidHeartbeat: Any in ["not a timestamp", NSNull(), true] {
            var row = silvermoon
            row["Lastupdate"] = invalidHeartbeat
            try rejectsRealm(realmEnvelope([row]), "A malformed heartbeat must surface as unknown")
        }
        try rejectsRealm(realmEnvelope([]), "An absent Silvermoon realm is an unavailable result")
        try rejectsRealm(realmEnvelope([realmRow(id: 7, name: "Sibling")]), "Another realm cannot supply Silvermoon's status")
        try rejectsRealm(realmEnvelope([silvermoon], errorID: 5), "Realm API ErrorID must be surfaced")
        try rejectsRealm(json(["error": ["code": -32603, "message": "Internal error"]]), "A realm RPC error must not appear offline")
        try rejectsRealm(json(["result": ["ErrorID": 0, "Realms": "unexpected"]]), "A changed realm collection shape is rejected")
        try rejectsRealm(json(["result": NSNull()]), "A null realm result is rejected")
        try rejectsRealm(Data("{broken json".utf8), "Malformed realm JSON is rejected")
        try rejectsRealm(Data("<html>Checking your browser</html>".utf8), "An HTML response is not realm status")

        let realmRequest = FirestormRealmService.makeRequest()
        try expect(realmRequest.url?.absoluteString == "https://api.firestorm-servers.com/cgi-bin/processACT", "Realm requests use the public launcher HTTPS API")
        try expect(realmRequest.httpMethod == "POST", "Realm status uses the public JSON-RPC POST")
        try expect(realmRequest.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true, "Realm RPC declares JSON")
        let realmRPC = try requestJSON(realmRequest)
        try expect(realmRPC["method"] as? String == "GetAllRealmsInfo", "Realm status calls GetAllRealmsInfo")
        let realmParameters = realmRPC["params"] as? [Any] ?? []
        try expect(realmParameters.count == 1, "Realm status sends only public client context, with no account or global-total request")
        let realmContext = realmParameters.first as? String ?? ""
        try expect(realmContext.count == 40 && realmContext.allSatisfy { $0.isASCII && $0.isHexDigit }, "Realm context uses the public launcher identifier shape")
        try expect(realmRequest.value(forHTTPHeaderField: "Authorization") == nil, "Realm status adds no account authorization")

        // Patches are their own category/subcategory and are commonly hidden
        // from the news homepage. They must retain the complete patch text.
        let localized = fixesRow(701, english: "Midnight fixes", russian: "Исправления Midnight")
        let english = try FirestormFixesService.decodeAPI(fixesEnvelope([localized]), language: "en")
        let russian = try FirestormFixesService.decodeAPI(fixesEnvelope([localized]), language: "ru")
        try expect(english.count == 1 && russian.count == 1, "Homepage-hidden category 2/subcategory 34 fixes are included")
        try expect(english[0].title == "Midnight fixes", "Fixes choose English locale 0")
        try expect(russian[0].title == "Исправления Midnight", "Fixes choose Russian locale 4")
        try expect(english[0].bodyText.contains("First paragraph"), "English fixes content is localized")
        try expect(russian[0].bodyText.contains("Первый абзац"), "Russian fixes content is localized")
        try expect(english[0].articleURL.absoluteString == "https://firestorm-servers.com/en/news/701", "Each fix opens its individual official English article")
        try expect(russian[0].articleURL.absoluteString == "https://firestorm-servers.com/ru/news/701", "Each fix opens its individual official Russian article")
        try expect(english[0].publishedAt?.timeIntervalSince1970 == 1795024285, "Fixes retain their publication date")

        var fallbackRow = localized
        fallbackRow["Title"] = ["0": ["Locale": 0, "Value": "English fallback"]]
        fallbackRow["Content"] = ["0": ["Locale": 0, "Value": "<p>English body fallback</p>"]]
        let fallback = try FirestormFixesService.decodeAPI(fixesEnvelope([fallbackRow]), language: "ru")[0]
        try expect(fallback.title == "English fallback" && fallback.bodyText.contains("English body fallback"), "Missing Russian title and body fall back to English")
        var firstLanguage = localized
        firstLanguage["Title"] = ["1": ["Locale": 1, "Value": "Titre disponible"]]
        firstLanguage["Content"] = ["1": ["Locale": 1, "Value": "<p>Contenu disponible</p>"]]
        let firstFallback = try FirestormFixesService.decodeAPI(fixesEnvelope([firstLanguage]), language: "en")[0]
        try expect(firstFallback.title == "Titre disponible" && firstFallback.bodyText.contains("Contenu disponible"), "Another available translation is used when English is absent")
        var arrayLanguages = localized
        arrayLanguages["Title"] = [["Locale": 0, "Value": "Array English"], ["Locale": 4, "Value": "Из массива"]]
        arrayLanguages["Content"] = [["Locale": 0, "Value": "English body"], ["Locale": 4, "Value": "<p>Текст из массива</p>"]]
        let arrayFix = try FirestormFixesService.decodeAPI(fixesEnvelope([arrayLanguages]), language: "ru")[0]
        try expect(arrayFix.title == "Из массива" && arrayFix.bodyText.contains("Текст из массива"), "Fixes translations tolerate arrays as well as keyed objects")
        var emptyTranslation = fallbackRow
        emptyTranslation["Title"] = ["0": ["Locale": 0, "Value": "English fallback"], "4": ["Locale": 4, "Value": "  \n "]]
        emptyTranslation["Content"] = ["0": ["Locale": 0, "Value": "English body fallback"], "4": ["Locale": 4, "Value": "  "]]
        let emptyTranslationFix = try FirestormFixesService.decodeAPI(fixesEnvelope([emptyTranslation]), language: "ru")[0]
        try expect(emptyTranslationFix.title == "English fallback" && emptyTranslationFix.bodyText == "English body fallback", "Blank requested translations fall back to usable English content")

        let longTail = String(repeating: "A detailed correction remains visible. ", count: 30) + "END OF COMPLETE PATCH"
        var structured = localized
        structured["Title"] = ["0": ["Locale": 0, "Value": "<b>A &amp; B</b>"]]
        structured["Content"] = ["0": ["Locale": 0, "Value": """
            <h2>Dungeon fixes</h2><p>First paragraph.</p><p>Second paragraph.</p>
            <ul><li>First list correction</li><li><strong>Boss fixes</strong><ul><li>Nested correction</li></ul></li></ul>
            <p>\(longTail)</p><script>hiddenScriptMustNotRun()</script><style>.hiddenStyleMustNotAppear{}</style>
            """
        ]]
        let richFix = try FirestormFixesService.decodeAPI(fixesEnvelope([structured]), language: "en")[0]
        try expect(richFix.title == "A & B", "Fixes titles decode HTML entities as plain text")
        try expect(richFix.bodyText.contains("First paragraph.\n\nSecond paragraph."), "Separate body paragraphs retain a blank-line boundary")
        let richLines = richFix.bodyText.components(separatedBy: .newlines)
        try expect(richLines.contains { $0.trimmingCharacters(in: .whitespaces) == "Dungeon fixes" }, "A rich-text heading retains its own line")
        try expect(richLines.contains { $0.contains("First list correction") && !$0.contains("Nested correction") }, "A list item is not merged with later list entries")
        try expect(richLines.contains { $0.contains("Nested correction") && !$0.contains("First list correction") }, "A nested correction remains separately readable")
        try expect(richLines.contains { ($0.contains("•") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")) && $0.contains("First list correction") }, "HTML lists preserve a visible bullet marker")
        try expect(richFix.bodyText.count > 1000 && richFix.bodyText.hasSuffix("END OF COMPLETE PATCH"), "Full fixes are retained beyond the 200-character news summary limit")
        try expect(!richFix.bodyText.contains("hiddenScriptMustNotRun") && !richFix.bodyText.contains("hiddenStyleMustNotAppear"), "Script and style content is removed from fixes text")
        try expect(!richFix.bodyText.contains("<p>") && !richFix.bodyText.contains("<li>"), "Fixes display readable text rather than literal HTML")

        let entityFile = FileManager.default.temporaryDirectory.appendingPathComponent("firestorm-fixes-entity-\(UUID().uuidString).txt")
        let entityMarker = "EXTERNAL_ENTITY_MUST_NOT_BE_LOADED"
        try entityMarker.write(to: entityFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: entityFile) }
        var entityRow = localized
        entityRow["Content"] = ["0": ["Locale": 0, "Value": "<!DOCTYPE html [<!ENTITY fixture SYSTEM \"\(entityFile.absoluteString)\">]><p>Visible fix &fixture;</p>"]]
        let entityFix = try FirestormFixesService.decodeAPI(fixesEnvelope([entityRow]), language: "en")[0]
        try expect(entityFix.bodyText.contains("Visible fix") && !entityFix.bodyText.contains(entityMarker), "External entity declarations cannot read local files into displayed fixes")

        var newsCategory = fixesRow(702, english: "News item")
        newsCategory["CategoryID"] = 1
        var otherSubcategory = fixesRow(703, english: "Another expansion")
        otherSubcategory["SubCategoryID"] = 33
        var invisible = fixesRow(704, english: "Not yet published")
        invisible["Visible"] = 0
        var noTitle = fixesRow(705, english: "")
        noTitle["Title"] = NSNull()
        let filtered = try FirestormFixesService.decodeAPI(fixesEnvelope([
            newsCategory, otherSubcategory, invisible, noTitle,
            fixesRow(705, english: "Valid replacement"), fixesRow(705, english: "Duplicate"),
            localized, "invalid row", NSNull(), fixesRow(-1, english: "Invalid ID"),
        ]), language: "en")
        try expect(filtered.map(\.id) == ["705", "701"], "Fixes filter news/wrong subcategory/invisible rows and deduplicate valid IDs")
        try expect(filtered[0].title == "Valid replacement", "An invalid title does not reserve an otherwise valid fixes ID")
        let empty = try FirestormFixesService.decodeAPI(fixesEnvelope([]), language: "en")
        try expect(empty.isEmpty, "An empty successful fixes feed remains a valid empty state")
        try rejectsFixes(fixesEnvelope([localized], errorID: 5), "Fixes API errors must not appear as empty results")
        try rejectsFixes(json(["error": ["code": -32603, "message": "Internal error"]]), "Fixes RPC errors must be surfaced")
        try rejectsFixes(json(["result": ["ErrorID": 0, "News": "unexpected"]]), "A changed fixes collection shape is rejected")
        try rejectsFixes(json(["result": NSNull()]), "A null fixes result is rejected")
        try rejectsFixes(Data("{broken json".utf8), "Malformed fixes JSON is rejected")
        try rejectsFixes(Data("<html>Checking your browser</html>".utf8), "HTML challenges are not treated as an empty fixes feed")

        for (language, expectedLocale) in [("en", 0), ("ru", 4), ("unexpected", 0)] {
            let request = FirestormFixesService.makeRequest(language: language)
            try expect(request.url?.absoluteString == "https://api.firestorm-servers.com/cgi-bin/processACT", "Fixes use the original public launcher API")
            try expect(request.httpMethod == "POST", "Fixes RPC uses POST")
            try expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true, "Fixes RPC declares JSON")
            let rpc = try requestJSON(request)
            try expect(rpc["method"] as? String == "GetLauncherLastNews", "Fixes use GetLauncherLastNews")
            let parameters = rpc["params"] as? [Any] ?? []
            try expect(parameters.count == 4, "Fixes use exactly four public RPC parameters")
            guard parameters.count == 4 else { throw RealmFixesTestFailure(description: "Unexpected fixes parameter count") }
            let context = parameters[0] as? String ?? ""
            try expect(context.count == 40 && context.allSatisfy { $0.isASCII && $0.isHexDigit }, "Fixes use public client context without fixture credentials")
            try expect((parameters[1] as? NSNumber)?.intValue == 5, "Fixes request the latest five patch entries")
            try expect((parameters[2] as? NSNumber)?.intValue == expectedLocale, "Fixes request the selected interface locale")
            try expect(parameters[3] as? String == "34", "The last parameter selects Midnight's fixes subcategory, not an account")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Public fixes do not attach account authorization")
        }
        return checks
    }

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private static func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealmFixesTestFailure(description: "A public API request requires a JSON body")
        }
        return body
    }

    private static func realmEnvelope(_ realms: [Any], errorID: Int = 0) -> Data {
        json(["jsonrpc": "2.0", "result": ["ErrorID": errorID, "Realms": realms], "id": 1])
    }

    private static func realmRow(id: Any = 14, name: String = "Silvermoon", online: Any = 4058, updated: Any = 1000, security: Any = 0) -> [String: Any] {
        ["ID": id, "Name": name, "Online": online, "Lastupdate": updated, "AllowedSecurityLevel": security]
    }

    private static func fixesEnvelope(_ news: [Any], errorID: Int = 0) -> Data {
        json(["jsonrpc": "2.0", "result": ["ErrorID": errorID, "News": news], "id": 1])
    }

    private static func fixesRow(_ id: Any, english: String, russian: String? = nil) -> [String: Any] {
        var titles: [String: Any] = ["0": ["Locale": 0, "Value": english]]
        if let russian { titles["4"] = ["Locale": 4, "Value": russian] }
        return [
            "ID": id, "Date": "1795024285", "CategoryID": 2, "SubCategoryID": 34,
            "Visible": 1, "HideFromHomepage": 1, "Title": titles,
            "Content": [
                "0": ["Locale": 0, "Value": "<p>First paragraph of the complete patch.</p>"],
                "4": ["Locale": 4, "Value": "<p>Первый абзац полного списка исправлений.</p>"],
            ],
        ]
    }
}
