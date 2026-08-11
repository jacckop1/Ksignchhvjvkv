import Foundation
import ZIPFoundation

struct AppStorePackageSinf: Sendable {
    let id: Int64
    let data: Data
}

struct AppStorePackagePayload: Sendable {
    let sinfs: [AppStorePackageSinf]
    let iTunesMetadata: Data
}

enum AppStorePackageFinalizerError: LocalizedError {
    case invalidArchive
    case appPayloadNotFound
    case infoPlistInvalid
    case executableNotFound
    case missingSinf

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return "حزمة App Store التي تم تنزيلها ليست أرشيف IPA صالحاً."
        case .appPayloadNotFound:
            return "لم يتم العثور على Payload داخل حزمة App Store."
        case .infoPlistInvalid:
            return "تعذر قراءة Info.plist من حزمة App Store."
        case .executableNotFound:
            return "تعذر تحديد الملف التنفيذي للتطبيق داخل الحزمة."
        case .missingSinf:
            return "لم يرجع App Store بيانات SINF اللازمة لإعادة تكوين الحزمة الأصلية."
        }
    }
}

/// يعيد تكوين حزمة App Store الرسمية بعد تنزيل ملف الـ CDN الخام.
/// هذه العملية لا تفك FairPlay ولا تعدل الملف التنفيذي؛ فقط تعيد ملفات
/// SINF و iTunesMetadata التي ترجعها Apple مع تذكرة التنزيل.
enum AppStorePackageFinalizer {
    static func finalize(archiveURL: URL, payload: AppStorePackagePayload) throws {
        guard !payload.sinfs.isEmpty else {
            throw AppStorePackageFinalizerError.missingSinf
        }

        guard let archive = Archive(url: archiveURL, accessMode: .update) else {
            throw AppStorePackageFinalizerError.invalidArchive
        }

        guard let infoEntry = archive.first(where: { entry in
            entry.path.hasPrefix("Payload/") &&
            entry.path.hasSuffix(".app/Info.plist") &&
            entry.path.components(separatedBy: "/").count == 3
        }) else {
            throw AppStorePackageFinalizerError.appPayloadNotFound
        }

        let appPath = infoEntry.path
            .split(separator: "/")
            .prefix(2)
            .joined(separator: "/")

        let infoData = try read(entry: infoEntry, from: archive)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AppStorePackageFinalizerError.infoPlistInvalid
        }

        let manifestPath = "\(appPath)/SC_Info/Manifest.plist"
        let sinfPaths = try sinfPaths(from: archive[manifestPath], archive: archive)
        let targetPaths: [String]

        if let sinfPaths, !sinfPaths.isEmpty, sinfPaths.count == payload.sinfs.count {
            targetPaths = sinfPaths.map { path in
                let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
                return "\(appPath)/\(normalized)"
            }
        } else {
            guard let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty else {
                throw AppStorePackageFinalizerError.executableNotFound
            }
            targetPaths = ["\(appPath)/SC_Info/\(executable).sinf"]
        }

        // إذا ماكو Manifest متعدد، أول SINF هو الخاص بالملف التنفيذي الرئيسي.
        let sinfsToWrite = targetPaths.count == payload.sinfs.count
            ? payload.sinfs
            : [payload.sinfs[0]]

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ksign-AppStoreFinalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        if !payload.iTunesMetadata.isEmpty {
            try replaceEntry(
                path: "iTunesMetadata.plist",
                data: payload.iTunesMetadata,
                archive: archive,
                tempDirectory: tempDirectory
            )
        }

        for (path, sinf) in zip(targetPaths, sinfsToWrite) {
            try replaceEntry(
                path: path,
                data: sinf.data,
                archive: archive,
                tempDirectory: tempDirectory
            )
        }
    }

    private static func sinfPaths(from entry: Entry?, archive: Archive) throws -> [String]? {
        guard let entry else { return nil }
        let data = try read(entry: entry, from: archive)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }
        return plist["SinfPaths"] as? [String]
    }

    private static func read(entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            data.append(chunk)
        })
        return data
    }

    private static func replaceEntry(
        path: String,
        data: Data,
        archive: Archive,
        tempDirectory: URL
    ) throws {
        if let oldEntry = archive[path] {
            try archive.remove(oldEntry)
        }

        let safeName = UUID().uuidString
        let fileURL = tempDirectory.appendingPathComponent(safeName)
        try data.write(to: fileURL, options: .atomic)
        try archive.addEntry(with: path, fileURL: fileURL)
    }
}
