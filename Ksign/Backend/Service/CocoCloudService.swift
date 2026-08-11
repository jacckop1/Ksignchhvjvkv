//
//  CocoCloudService.swift
//  Ksign
//
//  يرسل رابط IPA فقط + الشهادة + البروفايل
//  نفس طريقة الموقع السريع
//

import Foundation
import CoreData
import UserNotifications

struct CocoCloudSignResponse: Decodable {
    let success: Bool?

    let itmsServicesUrl: String?
    let otaUrl: String?
    let ota_url: String?
    let installUrl: String?
    let install_url: String?

    let manifestUrl: String?
    let manifest_url: String?
    let plistUrl: String?
    let plist_url: String?

    let error: String?
    let message: String?
    let data: ResponseData?

    struct ResponseData: Decodable {
        let itmsServicesUrl: String?
        let otaUrl: String?
        let ota_url: String?
        let installUrl: String?
        let install_url: String?

        let manifestUrl: String?
        let manifest_url: String?
        let plistUrl: String?
        let plist_url: String?
    }
}

enum CocoCloudError: LocalizedError {
    case noCertificate
    case missingCertFile
    case invalidURL
    case apiError(String)
    case noInstallURL
    case invalidResponse(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noCertificate:
            return "لا توجد شهادة مضافة."
        case .missingCertFile:
            return "ملف الشهادة أو ملف mobileprovision غير موجود."
        case .invalidURL:
            return "رابط السيرفر غير صحيح."
        case .apiError(let msg):
            return msg
        case .noInstallURL:
            return "السيرفر لم يرجع رابط تثبيت."
        case .invalidResponse(let msg):
            return "استجابة غير صالحة: \(msg)"
        case .networkError(let err):
            return err.localizedDescription
        }
    }
}

final class CocoCloudService {

    static let shared = CocoCloudService()

    // غيّر هذا إذا رابط الوركر عندك مختلف
    private let signerWorkerURL = "https://kirasign-app-signer.ikiraplus.workers.dev/sign"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    private func getDefaultCertificate() -> CertificatePair? {
        let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]

        guard let allCerts = try? Storage.shared.context.fetch(request),
              !allCerts.isEmpty else {
            return nil
        }

        let selectedIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
        if selectedIndex < allCerts.count {
            return allCerts[selectedIndex]
        }

        return allCerts.first
    }

    func signWithUserCert(
        ipaURL: String,
        bundleIdOverride: String? = nil,
        appNameOverride: String? = nil,
        appDisplayName: String? = nil,
        onProgress: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let cert = getDefaultCertificate() else {
            completion(.failure(CocoCloudError.noCertificate))
            return
        }

        guard
            let p12URL = Storage.shared.getFile(.certificate, from: cert),
            let provisionURL = Storage.shared.getFile(.provision, from: cert),
            let p12Data = try? Data(contentsOf: p12URL),
            let provisionData = try? Data(contentsOf: provisionURL)
        else {
            completion(.failure(CocoCloudError.missingCertFile))
            return
        }

        guard let url = URL(string: signerWorkerURL) else {
            completion(.failure(CocoCloudError.invalidURL))
            return
        }

        let cleanIPAURL = ipaURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanIPAURL.hasPrefix("http://") || cleanIPAURL.hasPrefix("https://") else {
            completion(.failure(CocoCloudError.apiError("الـ IPA لازم ينرسل كرابط مباشر، مو كملف.")))
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let password = cert.password ?? ""

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = Data()

        // الأهم: هنا نرسل الرابط كنص فقط
        body.addField(name: "ipa", value: cleanIPAURL, boundary: boundary)

        // اختياري
        if let bundleIdOverride,
           !bundleIdOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.addField(name: "bundleId", value: bundleIdOverride, boundary: boundary)
        }

        if let appNameOverride,
           !appNameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.addField(name: "bundleName", value: appNameOverride, boundary: boundary)
        }

        // الشهادة
        body.addFile(
            name: "cert",
            filename: p12URL.lastPathComponent.isEmpty ? "cert.p12" : p12URL.lastPathComponent,
            data: p12Data,
            mime: "application/x-pkcs12",
            boundary: boundary
        )

        // البروفايل
        body.addFile(
            name: "provision",
            filename: provisionURL.lastPathComponent.isEmpty ? "profile.mobileprovision" : provisionURL.lastPathComponent,
            data: provisionData,
            mime: "application/octet-stream",
            boundary: boundary
        )

        if !password.isEmpty {
            body.addField(name: "password", value: password, boundary: boundary)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        DispatchQueue.main.async {
            onProgress("جاري إرسال رابط التطبيق للسيرفر...")
        }

        let started = Date()

        let task = session.uploadTask(with: request, from: body) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(CocoCloudError.networkError(error)))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard let data, !data.isEmpty else {
                completion(.failure(CocoCloudError.invalidResponse("رد فارغ من السيرفر")))
                return
            }

            let rawPreview = String(data: data.prefix(500), encoding: .utf8) ?? ""

            do {
                let result = try JSONDecoder().decode(CocoCloudSignResponse.self, from: data)

                if !(200...299).contains(statusCode) {
                    let msg = result.error ?? result.message ?? rawPreview
                    completion(.failure(CocoCloudError.apiError(msg)))
                    return
                }

                if result.success == false {
                    let msg = result.error ?? result.message ?? "فشل التوقيع"
                    completion(.failure(CocoCloudError.apiError(msg)))
                    return
                }

                guard let installURL = self.extractInstallURL(from: result) else {
                    completion(.failure(CocoCloudError.noInstallURL))
                    return
                }

                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))

                DispatchQueue.main.async {
                    onProgress("اكتمل التوقيع خلال \(seconds) ثانية")
                    self.sendNotification(
                        title: "✅ اكتمل التوقيع",
                        body: "اضغط لتثبيت \(appDisplayName ?? "التطبيق")",
                        itmsURL: installURL
                    )
                }

                completion(.success(installURL))

            } catch {
                completion(.failure(CocoCloudError.invalidResponse(rawPreview)))
            }
        }

        DispatchQueue.main.async {
            onProgress("جاري التوقيع...")
        }

        task.resume()
    }

    private func extractInstallURL(from result: CocoCloudSignResponse) -> String? {
        let installCandidates: [String?] = [
            result.itmsServicesUrl,
            result.otaUrl,
            result.ota_url,
            result.installUrl,
            result.install_url,
            result.data?.itmsServicesUrl,
            result.data?.otaUrl,
            result.data?.ota_url,
            result.data?.installUrl,
            result.data?.install_url
        ]

        for item in installCandidates {
            if let value = item?.trimmingCharacters(in: .whitespacesAndNewlines),
               value.hasPrefix("itms-services://") {
                return value
            }
        }

        let plistCandidates: [String?] = [
            result.manifestUrl,
            result.manifest_url,
            result.plistUrl,
            result.plist_url,
            result.data?.manifestUrl,
            result.data?.manifest_url,
            result.data?.plistUrl,
            result.data?.plist_url
        ]

        for item in plistCandidates {
            if let value = item?.trimmingCharacters(in: .whitespacesAndNewlines),
               value.hasPrefix("http") {
                return makeItmsURL(fromPlist: value)
            }
        }

        return nil
    }

    private func makeItmsURL(fromPlist plistURL: String) -> String {
        let encoded = plistURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? plistURL
        return "itms-services://?action=download-manifest&url=\(encoded)"
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func sendNotification(title: String, body: String, itmsURL: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        if let itmsURL {
            content.userInfo = ["itmsURL": itmsURL]
        }

        let request = UNNotificationRequest(
            identifier: "KiraSign.signing.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}

private extension Data {

    mutating func addField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func addFile(
        name: String,
        filename: String,
        data fileData: Data,
        mime: String,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
