//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//
//  MODIFIED: بدل فك ضغط الـ IPA وتخزين .app مجلد ضخم،
//  نخزّن الـ IPA مباشرة ونستخرج المعلومات منه بدون فك ضغط كامل.
//

import Foundation
import ZIPFoundation
import SwiftUI
import Foundation.NSByteCountFormatter

final class AppFileHandler: NSObject, @unchecked Sendable {
    private let _fileManager = FileManager.default
    private let _uuid = UUID().uuidString
    private let _uniqueWorkDir: URL
    
    // المسار النهائي للـ IPA المخزّن
    private var _storedIpaURL: URL?

    private var _ipa: URL
    private let _install: Bool
    private let _download: Download?
    
    // معلومات مستخرجة من الـ IPA بدون فك ضغط كامل
    private var _appName: String?
    private var _appIdentifier: String?
    private var _appVersion: String?
    private var _appIcon: String?
    
    init(
        file ipa: URL,
        install: Bool = false,
        download: Download? = nil
    ) {
        self._ipa = ipa
        self._install = install
        self._download = download
        self._uniqueWorkDir = _fileManager.temporaryDirectory
            .appendingPathComponent("FeatherImport_\(_uuid)", isDirectory: true)
        
        super.init()
        print("Import initiated for: \(_ipa.lastPathComponent) with ID: \(_uuid)")
    }
    
    func copy() async throws {
        try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
        
        let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)
        try _fileManager.removeFileIfNeeded(at: destinationURL)
        try _fileManager.copyItem(at: _ipa, to: destinationURL)
        _ipa = destinationURL
        print("[\(_uuid)] File copied to: \(_ipa.path)")
    }
    
    // MARK: - استخراج المعلومات من الـ IPA مباشرة (بدون فك ضغط كامل)
    func extract() async throws {
        // نبلّغ عن بداية المعالجة
        if let download = _download {
            await MainActor.run { download.unpackageProgress = 0.1 }
        }
        
        guard let archive = Archive(url: _ipa, accessMode: .read) else {
            throw ImportedFileHandlerError.extractionFailed
        }
        
        // نبحث عن Info.plist داخل Payload/*.app/
        guard let infoPlistEntry = archive.first(where: {
            $0.path.hasPrefix("Payload/") &&
            $0.path.hasSuffix(".app/Info.plist") &&
            $0.path.components(separatedBy: "/").count == 3
        }) else {
            throw ImportedFileHandlerError.payloadNotFound
        }
        
        if let download = _download {
            await MainActor.run { download.unpackageProgress = 0.4 }
        }
        
        // نستخرج Info.plist فقط
        var plistData = Data()
        _ = try? archive.extract(infoPlistEntry, consumer: { plistData.append($0) })
        
        if let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            _appName       = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
            _appIdentifier = plist["CFBundleIdentifier"] as? String
            _appVersion    = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
            
            // اسم أيقونة التطبيق - بحث شامل في جميع مفاتيح الأيقونات
            var iconNameFound: String? = nil
            
            // محاولة CFBundleIcons (iOS الحديث)
            if let icons = plist["CFBundleIcons"] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String],
               let iconName = files.last {
                iconNameFound = _findIconEntry(in: archive, appPath: _appPath(from: infoPlistEntry), iconName: iconName)
            }
            
            // محاولة CFBundleIconFiles المباشر
            if iconNameFound == nil,
               let files = plist["CFBundleIconFiles"] as? [String],
               let iconName = files.last {
                iconNameFound = _findIconEntry(in: archive, appPath: _appPath(from: infoPlistEntry), iconName: iconName)
            }
            
            // محاولة CFBundleIconName
            if iconNameFound == nil,
               let iconName = plist["CFBundleIconName"] as? String {
                iconNameFound = _findIconEntry(in: archive, appPath: _appPath(from: infoPlistEntry), iconName: iconName)
            }
            
            // fallback: بحث مباشر عن أي AppIcon في الـ archive
            if iconNameFound == nil {
                iconNameFound = _findIconEntry(in: archive, appPath: _appPath(from: infoPlistEntry), iconName: "AppIcon")
            }
            
            _appIcon = iconNameFound
        }
        
        if let download = _download {
            await MainActor.run { download.unpackageProgress = 0.7 }
        }
        
        // إذا وجدنا أيقونة نستخرجها فقط
        if let iconName = _appIcon {
            let appPath = _appPath(from: infoPlistEntry)
            _extractIcon(from: archive, appPath: appPath, iconName: iconName)
        }
        
        if let download = _download {
            await MainActor.run { download.unpackageProgress = 1.0 }
        }
    }
    
    // MARK: - نقل الـ IPA مباشرة (بدون فك ضغط)
    func move() async throws {
        let destDir = try await _directory()
        try _fileManager.createDirectoryIfNeeded(at: destDir)
        
        // نسمّي الـ IPA باسم التطبيق
        let ipaName = (_appName ?? _ipa.deletingPathExtension().lastPathComponent) + ".ipa"
        let destURL = destDir.appendingPathComponent(ipaName)
        
        try _fileManager.removeFileIfNeeded(at: destURL)
        try _fileManager.moveItem(at: _ipa, to: destURL)
        _storedIpaURL = destURL
        
        // نحفظ الأيقونة بجانب الـ IPA إذا استخرجناها
        let iconSrc = _uniqueWorkDir.appendingPathComponent("_icon_extracted")
        if _fileManager.fileExists(atPath: iconSrc.path), let iconName = _appIcon {
            let iconDest = destDir.appendingPathComponent(iconName)
            try? _fileManager.moveItem(at: iconSrc, to: iconDest)
        }
        
        try? _fileManager.removeItem(at: _uniqueWorkDir)
        print("[\(_uuid)] Stored IPA at: \(destURL.path)")
    }
    
    func addToDatabase() async throws {
        guard let storedURL = _storedIpaURL else { return }
        
        Storage.shared.addImported(
            uuid: _uuid,
            source: storedURL,           // ← الـ IPA مباشرة
            appName: _appName,
            appIdentifier: _appIdentifier,
            appVersion: _appVersion,
            appIcon: _appIcon            // ← اسم ملف الأيقونة المستخرجة
        ) { _ in
            print("[\(self._uuid)] Added to database")
        }
    }
    
    private func _directory() async throws -> URL {
        // Documents/App/Unsigned/UUID/
        _fileManager.unsigned(_uuid)
    }
    
    func clean() async throws {
        try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
    }
    
    // MARK: - Helpers
    
    /// يستخرج مسار الـ .app من مسار Info.plist
    private func _appPath(from entry: Entry) -> String {
        // "Payload/MyApp.app/Info.plist" → "Payload/MyApp.app"
        let components = entry.path.components(separatedBy: "/")
        return components.prefix(2).joined(separator: "/")
    }
    
    /// يبحث عن الأيقونة المناسبة في الـ archive ويرجع اسم الملف
    private func _findIconEntry(in archive: Archive, appPath: String, iconName: String) -> String? {
        // 1) بحث مباشر بالاحقيات الشائعة
        let suffixes = ["@3x.png", "@2x.png", ".png"]
        for suffix in suffixes {
            let candidate = "\(appPath)/\(iconName)\(suffix)"
            if archive.first(where: { $0.path == candidate }) != nil {
                return "\(iconName)\(suffix)"
            }
        }
        // 2) بحث جزئي داخل نفس الـ .app
        let found = archive.first(where: {
            $0.path.hasPrefix("\(appPath)/\(iconName)") && $0.path.hasSuffix(".png")
        })
        if let found = found {
            return URL(fileURLWithPath: found.path).lastPathComponent
        }
        // 3) fallback: أي أيقونة AppIcon داخل الـ .app
        let fallback = archive.first(where: {
            $0.path.hasPrefix("\(appPath)/") &&
            ($0.path.contains("AppIcon") || $0.path.contains("Icon")) &&
            $0.path.hasSuffix(".png") &&
            !$0.path.contains("@2x~ipad") // نتجنب نسخ iPad كأولوية
        })
        return fallback.map { URL(fileURLWithPath: $0.path).lastPathComponent }
    }
    
    /// يستخرج ملف الأيقونة فقط من الـ archive ويحفظه مؤقتاً
    private func _extractIcon(from archive: Archive, appPath: String, iconName: String) {
        guard let entry = archive.first(where: {
            $0.path == "\(appPath)/\(iconName)"
        }) else { return }
        
        let dest = _uniqueWorkDir.appendingPathComponent("_icon_extracted")
        var data = Data()
        _ = try? archive.extract(entry, consumer: { data.append($0) })
        try? data.write(to: dest)
    }
}

enum ImportedFileHandlerError: Error, CustomStringConvertible {
    case payloadNotFound
    case notEnoughDiskSpace(needed: Int64, available: Int64)
    case extractionFailed
    case zipLibraryNotAvailable
    
    var description: String {
        switch self {
        case .payloadNotFound:
            return "No Payload folder was found in the archive. The file may be corrupted."
        case .notEnoughDiskSpace(let needed, let available):
            let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let availableStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough disk space. Needed: \(neededStr), Available: \(availableStr)"
        case .extractionFailed:
            return "Failed to extract the archive. The file may be corrupted."
        case .zipLibraryNotAvailable:
            return "Zip library is not available on this platform."
        }
    }
}
