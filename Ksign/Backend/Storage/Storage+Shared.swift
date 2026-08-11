//
//  Storage+Shared.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import ZIPFoundation

// MARK: - Class extension: Apps (Shared)
extension Storage {
    func getUuidDirectory(for app: AppInfoPresentable) -> URL? {
        guard let uuid = app.uuid else { return nil }
        return app.isSigned
        ? FileManager.default.signed(uuid)
        : FileManager.default.unsigned(uuid)
    }
    
    /// للـ Signed: يرجع مسار الـ IPA (إذا كان مخزوناً كـ IPA) أو .app مجلد
    /// للـ Imported: يرجع مسار الـ IPA مباشرة (source)
    func getAppDirectory(for app: AppInfoPresentable) -> URL? {
        // Imported → source هو الـ IPA نفسه
        if let imported = app as? Imported {
            return imported.source
        }
        // Signed → أولاً نتحقق من source (IPA مباشرة)
        if let signed = app as? Signed, let source = signed.source {
            return source
        }
        // fallback: المجلد يحتوي .app (النمط القديم)
        guard let url = getUuidDirectory(for: app) else { return nil }
        return FileManager.default.getPath(in: url, for: "app")
    }
    
    /// يرجع الـ IPA مباشرة للـ Imported، أو يبني IPA مؤقت من .app للـ Signed
    func getIPAPath(for app: AppInfoPresentable) -> URL? {
        if let imported = app as? Imported {
            return imported.source
        }
        guard let url = getUuidDirectory(for: app) else { return nil }
        return FileManager.default.getPath(in: url, for: "ipa")
            ?? FileManager.default.getPath(in: url, for: "app")
    }

    func deleteApp(for app: AppInfoPresentable) {
        do {
            if let url = getUuidDirectory(for: app) {
                try? FileManager.default.removeItem(at: url)
            }
            if let object = app as? NSManagedObject {
                context.delete(object)
            }
            saveContext()
        }
    }
    
    func getCertificate(from app: AppInfoPresentable) -> CertificatePair? {
        if let signed = app as? Signed {
            return signed.certificate
        }
        return nil
    }
}

// MARK: - Helpers
struct AnyApp: Identifiable {
    let base: AppInfoPresentable
    var archive: Bool = false
    var signAndInstall: Bool = false
    
    var id: String {
        base.uuid ?? UUID().uuidString
    }
}

protocol AppInfoPresentable {
    var name: String? { get }
    var version: String? { get }
    var identifier: String? { get }
    var date: Date? { get }
    var icon: String? { get }
    var uuid: String? { get }
    var isSigned: Bool { get }
}

extension Signed: AppInfoPresentable {
    var isSigned: Bool { true }
}

extension Imported: AppInfoPresentable {
    var isSigned: Bool { false }
}

// MARK: - App Directory (with IPA extraction)
extension Storage {
    /// يرجع مسار .app جاهز للقراءة:
    /// - للـ Signed بمجلد .app مباشرة: يرجعه فوراً
    /// - للـ Imported أو Signed بـ IPA: يفك الضغط في مجلد مؤقت ويرجع .app
    /// المستدعي مسؤول عن حذف extractedTempDir بعد الانتهاء
    func resolveAppDir(for app: AppInfoPresentable) throws -> (appDir: URL, extractedTempDir: URL?) {
        let fm = FileManager.default

        // Signed بمجلد .app مباشرة
        if let signed = app as? Signed, signed.source == nil,
           let uuidDir = getUuidDirectory(for: app),
           let appDir  = fm.getPath(in: uuidDir, for: "app") {
            return (appDir, nil)
        }

        // IPA (Imported أو Signed.source)
        guard let ipaURL = getIPAPath(for: app) else {
            throw ResolveError.notFound
        }
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw ResolveError.cantRead
        }

        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("StorageResolve_\(UUID().uuidString)")
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        for entry in archive {
            guard entry.path.hasPrefix("Payload/"), !entry.path.hasPrefix("__MACOSX") else { continue }
            let dest = tmpDir.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            default:
                try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                _ = try? archive.extract(entry, to: dest)
            }
        }

        let payloadDir = tmpDir.appendingPathComponent("Payload")
        let apps = (try? fm.contentsOfDirectory(at: payloadDir,
                                                 includingPropertiesForKeys: nil)) ?? []
        guard let appDir = apps.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            throw ResolveError.noApp
        }

        return (appDir, tmpDir)
    }
}

enum ResolveError: LocalizedError {
    case notFound, cantRead, noApp
    var errorDescription: String? {
        switch self {
        case .notFound: return "لم يتم العثور على ملف التطبيق"
        case .cantRead: return "لا يمكن فتح ملف IPA"
        case .noApp:    return "لم يتم العثور على مجلد .app"
        }
    }
}
