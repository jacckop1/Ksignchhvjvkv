import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public models used by the App Store import UI

struct AppStoreSoftware: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: Int64
    let bundleID: String
    let name: String
    let version: String
    let price: Double?
    let artistName: String
    let sellerName: String
    let appDescription: String
    let averageUserRating: Double
    let userRatingCount: Int
    let artworkUrl: String
    let screenshotUrls: [String]
    let minimumOsVersion: String
    let fileSizeBytes: String?
    let releaseDate: String
    let formattedPrice: String?
    let primaryGenreName: String
}

struct AppStoreAccount: Codable, Equatable, Sendable {
    var email: String
    var password: String
    var appleID: String
    var storeFront: String
    var firstName: String
    var lastName: String
    var passwordToken: String
    var dsid: String
    var cookies: [AppStoreCookie]
    var pod: String?
}

struct AppStoreCookie: Codable, Equatable, Hashable, Sendable {
    var name: String
    var value: String
    var path: String
    var domain: String?
    var expiresAt: TimeInterval?
    var httpOnly: Bool
    var secure: Bool
}

enum AppStoreImportError: LocalizedError, Equatable {
    case invalidLink
    case appNotFound
    case invalidDownloadURL
    case missingCredentials
    case verificationCodeRequired
    case invalidVerificationCode
    case authenticationFailed(String)
    case malformedResponse(String)
    case licenseRequired
    case paidAppsNotSupported
    case purchaseFailed(String)
    case requestFailed(Int)
    case rateLimited
    case browserSignInRequired
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "رابط App Store غير صالح. الصق رابط التطبيق الكامل أو رقم App ID."
        case .appNotFound:
            return "لم يتم العثور على التطبيق في App Store لهذا البلد."
        case .invalidDownloadURL:
            return "رجع App Store رابط تنزيل غير صالح."
        case .missingCredentials:
            return "أدخل Apple ID وكلمة المرور أولاً."
        case .verificationCodeRequired:
            return "الحساب يطلب رمز التحقق بخطوتين. أدخل رمز 2FA ثم حاول مرة أخرى."
        case .invalidVerificationCode:
            return "رمز التحقق بخطوتين غير صحيح."
        case .authenticationFailed(let message):
            return "فشل تسجيل الدخول إلى App Store: \(message)"
        case .malformedResponse(let message):
            return "استجابة App Store غير متوقعة: \(message)"
        case .licenseRequired:
            return "الحساب لا يملك ترخيص هذا التطبيق بعد."
        case .paidAppsNotSupported:
            return "السحب التلقائي يدعم التطبيقات المجانية فقط عند الحاجة للحصول على الترخيص."
        case .purchaseFailed(let message):
            return "تعذر إضافة التطبيق إلى مشتريات الحساب: \(message)"
        case .requestFailed(let status):
            return "فشل اتصال App Store (HTTP \(status))."
        case .rateLimited:
            return "Apple قيّدت محاولات تسجيل الدخول مؤقتاً (HTTP 429). انتظر قليلاً ثم حاول مرة أخرى، وابتعد عن تكرار تسجيل الدخول بسرعة."
        case .browserSignInRequired:
            return "هذا الحساب يحتاج تسجيل دخول أو قبول إجراء من موقع Apple أولاً، ثم ارجع وحاول مرة أخرى."
        case .sessionExpired:
            return "جلسة App Store المحفوظة انتهت. سجّل دخول Apple ID من جديد ثم أعد المحاولة."
        }
    }
}

// MARK: - Lookup response

private struct AppStoreLookupResponse: Decodable {
    let resultCount: Int
    let results: [AppStoreLookupItem]
}

private struct AppStoreLookupItem: Decodable {
    let trackId: Int64
    let bundleId: String
    let trackName: String
    let version: String
    let price: Double?
    let artistName: String?
    let sellerName: String?
    let description: String?
    let averageUserRating: Double?
    let userRatingCount: Int?
    let artworkUrl512: String?
    let artworkUrl100: String?
    let screenshotUrls: [String]?
    let minimumOsVersion: String?
    let fileSizeBytes: String?
    let currentVersionReleaseDate: String?
    let formattedPrice: String?
    let primaryGenreName: String?

    func asSoftware() -> AppStoreSoftware {
        AppStoreSoftware(
            id: trackId,
            bundleID: bundleId,
            name: trackName,
            version: version,
            price: price,
            artistName: artistName ?? sellerName ?? "",
            sellerName: sellerName ?? artistName ?? "",
            appDescription: description ?? "",
            averageUserRating: averageUserRating ?? 0,
            userRatingCount: userRatingCount ?? 0,
            artworkUrl: artworkUrl512 ?? artworkUrl100 ?? "",
            screenshotUrls: screenshotUrls ?? [],
            minimumOsVersion: minimumOsVersion ?? "",
            fileSizeBytes: fileSizeBytes,
            releaseDate: currentVersionReleaseDate ?? "",
            formattedPrice: formattedPrice,
            primaryGenreName: primaryGenreName ?? ""
        )
    }
}

// MARK: - Foundation-only App Store client

private final class AppStoreNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct AppStoreHTTPResponse {
    let data: Data
    let response: HTTPURLResponse
}

private enum AppStoreEndpoint {
    case volumeStore
    case redownload

    var externalVersionKey: String {
        switch self {
        case .volumeStore: return "externalVersionId"
        case .redownload: return "appExtVrsId"
        }
    }

    func url(pod: String?, guid: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .volumeStore:
            if let pod, !pod.isEmpty {
                components.host = "p\(pod)-buy.itunes.apple.com"
            } else {
                components.host = "p25-buy.itunes.apple.com"
            }
            components.path = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        case .redownload:
            components.host = "downloaddispatch.itunes.apple.com"
            components.path = "/r/redownload"
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = components.url else { throw AppStoreImportError.invalidDownloadURL }
        return url
    }
}

private enum KiraAppStoreClient {
    // Configurator-like UA used by the App Store private plist endpoints.
    static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    static let fallbackAuthEndpoint = URL(string: "https://auth.itunes.apple.com/auth/v1/native/fast/") ?? URL(fileURLWithPath: "/")

    static func randomDeviceIdentifier() -> String {
        let alphabet = Array("0123456789ABCDEF")
        return String((0..<12).compactMap { _ in alphabet.randomElement() })
    }

    static func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            result[key] = String(describing: value)
        }
        return result
    }

    static func header(_ name: String, in response: HTTPURLResponse) -> String? {
        let target = name.lowercased()
        for (key, value) in response.allHeaderFields {
            if String(describing: key).lowercased() == target {
                return String(describing: value)
            }
        }
        return nil
    }

    static func cookies(from response: HTTPURLResponse, url: URL) -> [AppStoreCookie] {
        let headers = responseHeaders(response)
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map { cookie in
            AppStoreCookie(
                name: cookie.name,
                value: cookie.value,
                path: cookie.path.isEmpty ? "/" : cookie.path,
                domain: cookie.domain.isEmpty ? nil : cookie.domain,
                expiresAt: cookie.expiresDate?.timeIntervalSince1970,
                httpOnly: cookie.isHTTPOnly,
                secure: cookie.isSecure
            )
        }
    }

    static func mergeCookies(_ incoming: [AppStoreCookie], into existing: inout [AppStoreCookie]) {
        var map: [String: AppStoreCookie] = [:]
        for cookie in existing {
            map[cookie.name + "|" + (cookie.domain ?? "") + "|" + cookie.path] = cookie
        }
        for cookie in incoming {
            map[cookie.name + "|" + (cookie.domain ?? "") + "|" + cookie.path] = cookie
        }
        existing = Array(map.values)
    }

    static func cookieHeader(for url: URL, cookies: [AppStoreCookie]) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let now = Date().timeIntervalSince1970

        let values = cookies.compactMap { cookie -> String? in
            guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return nil }
            if let expires = cookie.expiresAt, expires <= now { return nil }
            if cookie.secure, url.scheme?.lowercased() != "https" { return nil }

            if let domain = cookie.domain?.lowercased(), !domain.isEmpty {
                let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                guard host == normalized || host.hasSuffix("." + normalized) else { return nil }
            }

            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            if cookiePath != "/" {
                guard requestPath == cookiePath || requestPath.hasPrefix(cookiePath + "/") || (cookiePath.hasSuffix("/") && requestPath.hasPrefix(cookiePath)) else {
                    return nil
                }
            }
            return "\(cookie.name)=\(cookie.value)"
        }

        guard !values.isEmpty else { return nil }
        return values.joined(separator: "; ")
    }

    static func makeSession(blockRedirects: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        if blockRedirects {
            return URLSession(configuration: configuration, delegate: AppStoreNoRedirectDelegate(), delegateQueue: nil)
        }
        return URLSession(configuration: configuration)
    }

    static func perform(_ request: URLRequest, blockRedirects: Bool = true) async throws -> AppStoreHTTPResponse {
        let session = makeSession(blockRedirects: blockRedirects)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreImportError.malformedResponse("لا توجد استجابة HTTP")
        }
        return AppStoreHTTPResponse(data: data, response: http)
    }

    static func plistDictionary(_ data: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw AppStoreImportError.malformedResponse("البيانات ليست plist dictionary")
        }
        return dictionary
    }

    static func plistData(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    static func extractPlist(from data: Data) -> Data {
        guard let string = String(data: data, encoding: .utf8),
              let start = string.range(of: "<plist"),
              let end = string.range(of: "</plist>", options: [], range: start.lowerBound..<string.endIndex)
        else { return data }
        let fragment = String(string[start.lowerBound..<end.upperBound])
        return Data(fragment.utf8)
    }

    static func bagAuthEndpoint(guid: String) async -> URL {
        guard var components = URLComponents(string: "https://init.itunes.apple.com/bag.xml") else {
            return fallbackAuthEndpoint
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard let url = components.url else { return fallbackAuthEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        do {
            let result = try await perform(request, blockRedirects: false)
            guard (200...299).contains(result.response.statusCode) else { return fallbackAuthEndpoint }
            let dictionary = try plistDictionary(extractPlist(from: result.data))
            let urlBag = dictionary["urlBag"] as? [String: Any]
            let raw = (dictionary["authenticateAccount"] as? String) ?? (urlBag?["authenticateAccount"] as? String)
            guard let raw, var auth = URLComponents(string: raw) else { return fallbackAuthEndpoint }
            if auth.host == "auth.itunes.apple.com" {
                var path = auth.path
                while path.hasSuffix("/") { path.removeLast() }
                if !path.hasSuffix("/fast") { path += "/fast" }
                auth.path = path + "/"
            }
            return auth.url ?? fallbackAuthEndpoint
        } catch {
            return fallbackAuthEndpoint
        }
    }

    static func authenticate(email: String, password: String, code: String, guid: String) async throws -> AppStoreAccount {
        let authEndpoint = await bagAuthEndpoint(guid: guid)
        guard var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: true) else {
            throw AppStoreImportError.authenticationFailed("تعذر إنشاء رابط تسجيل الدخول")
        }
        components.queryItems = [URLQueryItem(name: "guid", value: guid)]
        guard var currentURL = components.url else {
            throw AppStoreImportError.authenticationFailed("تعذر إنشاء رابط تسجيل الدخول")
        }

        var cookies: [AppStoreCookie] = []
        var storeFront = ""
        var pod: String?
        var requestAttempt = 0
        var redirects = 0
        var lastError: Error?

        while requestAttempt < 2 && redirects <= 3 {
            do {
                let body: [String: Any] = [
                    "appleId": email,
                    "attempt": code.isEmpty ? "4" : "2",
                    "guid": guid,
                    "password": password + code,
                    "rmp": "0",
                    "why": "signIn"
                ]

                var request = URLRequest(url: currentURL)
                request.httpMethod = "POST"
                request.httpBody = try plistData(body)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
                if let cookie = cookieHeader(for: currentURL, cookies: cookies) {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }

                let result = try await perform(request, blockRedirects: true)
                mergeCookies(KiraAppStoreClient.cookies(from: result.response, url: currentURL), into: &cookies)

                if let sf = header("x-set-apple-store-front", in: result.response)?.split(separator: "-").first, !sf.isEmpty {
                    storeFront = String(sf)
                }
                if let podHeader = header("pod", in: result.response), !podHeader.isEmpty {
                    pod = podHeader
                }

                if [301, 302, 303, 307, 308].contains(result.response.statusCode) {
                    guard let location = header("location", in: result.response), let nextURL = URL(string: location) else {
                        throw AppStoreImportError.authenticationFailed("تحويل تسجيل الدخول بدون Location")
                    }
                    currentURL = nextURL
                    redirects += 1
                    continue
                }

                if result.response.statusCode == 429 {
                    throw AppStoreImportError.rateLimited
                }
                guard (200...299).contains(result.response.statusCode) else {
                    throw AppStoreImportError.requestFailed(result.response.statusCode)
                }
                guard !result.data.isEmpty else {
                    throw AppStoreImportError.authenticationFailed("رجعت Apple استجابة فارغة. حاول لاحقاً أو أعد تسجيل الدخول.")
                }

                let dictionary = try plistDictionary(result.data)
                let rawCustomerMessage = String(describing: dictionary["customerMessage"] ?? "")
                if rawCustomerMessage.localizedCaseInsensitiveContains("AMD-Action::SP") {
                    throw AppStoreImportError.browserSignInRequired
                }
                if let failureType = dictionary["failureType"] as? String,
                   failureType.isEmpty,
                   code.isEmpty,
                   dictionary["customerMessage"] as? String == "MZFinance.BadLogin.Configurator_message" {
                    throw AppStoreImportError.verificationCodeRequired
                }
                if String(describing: dictionary["failureType"] ?? "") == "5005" {
                    throw AppStoreImportError.invalidVerificationCode
                }

                let failureMessage = ((dictionary["dialog"] as? [String: Any])?["explanation"] as? String)
                    ?? (dictionary["customerMessage"] as? String)
                    ?? "تعذر قراءة معلومات الحساب"

                guard let info = dictionary["accountInfo"] as? [String: Any],
                      let address = info["address"] as? [String: Any],
                      let appleID = info["appleId"] as? String,
                      let firstName = address["firstName"] as? String,
                      let lastName = address["lastName"] as? String,
                      let passwordToken = dictionary["passwordToken"] as? String,
                      let dsid = dictionary["dsPersonId"] as? String,
                      !storeFront.isEmpty
                else {
                    throw AppStoreImportError.authenticationFailed(failureMessage)
                }

                return AppStoreAccount(
                    email: email,
                    password: password,
                    appleID: appleID,
                    storeFront: storeFront,
                    firstName: firstName,
                    lastName: lastName,
                    passwordToken: passwordToken,
                    dsid: dsid,
                    cookies: cookies,
                    pod: pod
                )
            } catch let error as AppStoreImportError {
                if error == .verificationCodeRequired ||
                    error == .invalidVerificationCode ||
                    error == .rateLimited ||
                    error == .browserSignInRequired {
                    throw error
                }
                lastError = error
                requestAttempt += 1
            } catch {
                lastError = error
                requestAttempt += 1
            }
        }

        if let error = lastError { throw error }
        throw AppStoreImportError.authenticationFailed("خطأ غير معروف")
    }

    static func purchase(app: AppStoreSoftware, account: inout AppStoreAccount, guid: String) async throws {
        guard (app.price ?? 0) <= 0 else { throw AppStoreImportError.paidAppsNotSupported }

        do {
            try await purchase(app: app, account: &account, guid: guid, pricing: "STDQ")
        } catch let error as AppStoreImportError {
            let text = error.localizedDescription.lowercased()
            if text.contains("2059") || text.contains("temporarily unavailable") || text.contains("غير متوفر") {
                try await purchase(app: app, account: &account, guid: guid, pricing: "GAME")
            } else {
                throw error
            }
        }
    }

    private static func purchase(app: AppStoreSoftware, account: inout AppStoreAccount, guid: String, pricing: String) async throws {
        let host: String
        if let pod = account.pod, !pod.isEmpty {
            host = "p\(pod)-buy.itunes.apple.com"
        } else {
            host = "buy.itunes.apple.com"
        }
        guard let url = URL(string: "https://\(host)/WebObjects/MZFinance.woa/wa/buyProduct") else {
            throw AppStoreImportError.purchaseFailed("رابط الشراء غير صالح")
        }

        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": guid,
            "needDiv": "0",
            "origPage": "Software-\(app.id)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricing,
            "productType": "C",
            "salableAdamId": app.id
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try plistData(payload)
        request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
        request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
        request.setValue("\(account.storeFront)-1", forHTTPHeaderField: "X-Apple-Store-Front")
        request.setValue(account.passwordToken, forHTTPHeaderField: "X-Token")
        if let cookie = cookieHeader(for: url, cookies: account.cookies) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let result = try await perform(request, blockRedirects: true)
        mergeCookies(cookies(from: result.response, url: url), into: &account.cookies)
        if result.response.statusCode == 429 { throw AppStoreImportError.rateLimited }
        guard result.response.statusCode == 200 else { throw AppStoreImportError.requestFailed(result.response.statusCode) }
        let dictionary = try plistDictionary(result.data)

        if let action = dictionary["action"] as? [String: Any],
           let link = (action["url"] as? String) ?? (action["URL"] as? String),
           link.hasSuffix("termsPage") {
            throw AppStoreImportError.purchaseFailed("الحساب يحتاج قبول شروط App Store أولاً")
        }

        if let failure = dictionary["failureType"] {
            let message = dictionary["customerMessage"] as? String
            throw AppStoreImportError.purchaseFailed("failureType: \(String(describing: failure))\(message.map { " — \($0)" } ?? "")")
        }

        guard dictionary["jingleDocType"] as? String == "purchaseSuccess",
              (dictionary["status"] as? NSNumber)?.intValue == 0 || dictionary["status"] as? Int == 0 else {
            throw AppStoreImportError.purchaseFailed("App Store لم يؤكد نجاح العملية")
        }
    }

    static func downloadInfo(app: AppStoreSoftware, account: inout AppStoreAccount, guid: String) async throws -> (URL, AppStorePackagePayload) {
        var dictionary = try await fetchProduct(endpoint: .volumeStore, app: app, account: &account, guid: guid)
        if String(describing: dictionary["failureType"] ?? "") == "5002" {
            dictionary = try await fetchProduct(endpoint: .redownload, app: app, account: &account, guid: guid)
        }

        if let failure = dictionary["failureType"] {
            let type = String(describing: failure)
            if type == "9610" { throw AppStoreImportError.licenseRequired }
            if type == "2034" || type == "2042" { throw AppStoreImportError.sessionExpired }
            let customer = dictionary["customerMessage"] as? String
            if let customer,
               customer.localizedCaseInsensitiveContains("password"),
               customer.localizedCaseInsensitiveContains("changed") {
                throw AppStoreImportError.sessionExpired
            }
            throw AppStoreImportError.malformedResponse("failureType: \(type)\(customer.map { " — \($0)" } ?? "")")
        }

        guard let songList = dictionary["songList"] as? [[String: Any]], let item = songList.first else {
            throw AppStoreImportError.malformedResponse("songList غير موجود")
        }
        guard let urlString = item["URL"] as? String, let url = URL(string: urlString) else {
            throw AppStoreImportError.invalidDownloadURL
        }
        guard var metadata = item["metadata"] as? [String: Any] else {
            throw AppStoreImportError.malformedResponse("metadata غير موجود")
        }

        metadata["apple-id"] = account.email
        metadata["userName"] = account.email
        let iTunesMetadata = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)

        var sinfs: [AppStorePackageSinf] = []
        if let rawSinfs = item["sinfs"] as? [[String: Any]] {
            for raw in rawSinfs {
                let id: Int64?
                if let value = raw["id"] as? Int64 { id = value }
                else if let value = raw["id"] as? Int { id = Int64(value) }
                else if let value = raw["id"] as? NSNumber { id = value.int64Value }
                else { id = nil }

                if let id, let data = raw["sinf"] as? Data {
                    sinfs.append(AppStorePackageSinf(id: id, data: data))
                }
            }
        }
        guard !sinfs.isEmpty else {
            throw AppStorePackageFinalizerError.missingSinf
        }

        return (url, AppStorePackagePayload(sinfs: sinfs, iTunesMetadata: iTunesMetadata))
    }

    private static func fetchProduct(endpoint: AppStoreEndpoint, app: AppStoreSoftware, account: inout AppStoreAccount, guid: String) async throws -> [String: Any] {
        var currentURL = try endpoint.url(pod: account.pod, guid: guid)
        var redirectCount = 0

        while redirectCount <= 3 {
            let payload: [String: Any] = [
                "creditDisplay": "",
                "guid": guid,
                "salableAdamId": app.id
            ]
            var request = URLRequest(url: currentURL)
            request.httpMethod = "POST"
            request.httpBody = try plistData(payload)
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(account.dsid, forHTTPHeaderField: "iCloud-DSID")
            request.setValue(account.dsid, forHTTPHeaderField: "X-Dsid")
            if let cookie = cookieHeader(for: currentURL, cookies: account.cookies) {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            let result = try await perform(request, blockRedirects: true)
            mergeCookies(cookies(from: result.response, url: currentURL), into: &account.cookies)

            if result.response.statusCode == 302 {
                guard let location = header("location", in: result.response), let next = URL(string: location) else {
                    throw AppStoreImportError.malformedResponse("302 بدون Location")
                }
                currentURL = next
                redirectCount += 1
                continue
            }

            if result.response.statusCode == 429 { throw AppStoreImportError.rateLimited }
            guard result.response.statusCode == 200 else {
                throw AppStoreImportError.requestFailed(result.response.statusCode)
            }
            return try plistDictionary(result.data)
        }

        throw AppStoreImportError.malformedResponse("عدد تحويلات App Store تجاوز الحد")
    }
}

// MARK: - UI-facing service

struct AppStoreImportService {
    static let accountKey = "Ksign.AppStoreImport.Account.v2"
    private static let deviceIdentifierKey = "Ksign.AppStoreImport.DeviceIdentifier.v2"

    static func deviceIdentifier() -> String {
        if let stored = KeychainHelper.read(key: deviceIdentifierKey), stored.count == 12 {
            return stored
        }
        let identifier = KiraAppStoreClient.randomDeviceIdentifier()
        try? KeychainHelper.save(key: deviceIdentifierKey, value: identifier)
        return identifier
    }

    static func parseLink(_ rawValue: String) throws -> (appID: Int64, countryCode: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appID = Int64(trimmed), appID > 0 { return (appID, "US") }

        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "apps.apple.com" || host.hasSuffix(".apps.apple.com") else {
            throw AppStoreImportError.invalidLink
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        let country = pathParts.first.flatMap { $0.count == 2 ? $0.uppercased() : nil } ?? "US"
        let pattern = #"(?:^|/)id(\d+)(?:/|$)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: trimmed),
              let appID = Int64(trimmed[idRange]) else {
            throw AppStoreImportError.invalidLink
        }
        return (appID, country)
    }

    static func lookup(_ rawValue: String) async throws -> AppStoreSoftware {
        let parsed = try parseLink(rawValue)
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw AppStoreImportError.invalidLink
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(parsed.appID)),
            URLQueryItem(name: "country", value: parsed.countryCode),
            URLQueryItem(name: "entity", value: "software")
        ]
        guard let url = components.url else { throw AppStoreImportError.invalidLink }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppStoreImportError.requestFailed(http.statusCode)
        }
        let result = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        guard result.resultCount > 0, let item = result.results.first else { throw AppStoreImportError.appNotFound }
        return item.asSoftware()
    }

    static func authenticate(email: String, password: String, code: String) async throws -> AppStoreAccount {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !password.isEmpty else { throw AppStoreImportError.missingCredentials }
        let account = try await KiraAppStoreClient.authenticate(
            email: cleanEmail,
            password: password,
            code: cleanCode,
            guid: deviceIdentifier()
        )
        try saveAccount(account)
        return account
    }

    static func loadAccount() -> AppStoreAccount? {
        guard let encoded = KeychainHelper.read(key: accountKey), let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(AppStoreAccount.self, from: data)
    }

    static func saveAccount(_ account: AppStoreAccount) throws {
        let data = try JSONEncoder().encode(account)
        try KeychainHelper.save(key: accountKey, value: data.base64EncodedString())
    }

    static func clearAccount() {
        KeychainHelper.delete(key: accountKey)
    }

    static func prepareDownload(app: AppStoreSoftware, account: inout AppStoreAccount) async throws -> (url: URL, payload: AppStorePackagePayload) {
        let guid = deviceIdentifier()
        do {
            let result = try await KiraAppStoreClient.downloadInfo(app: app, account: &account, guid: guid)
            try saveAccount(account)
            return (result.0, result.1)
        } catch AppStoreImportError.licenseRequired {
            guard (app.price ?? 0) <= 0 else { throw AppStoreImportError.paidAppsNotSupported }
            try await KiraAppStoreClient.purchase(app: app, account: &account, guid: guid)
            let result = try await KiraAppStoreClient.downloadInfo(app: app, account: &account, guid: guid)
            try saveAccount(account)
            return (result.0, result.1)
        }
    }
}
