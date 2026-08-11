//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//
//  MODIFIED: يدعم التصدير المباشر من IPA (للـ Imported apps)
//            بدل ما يحتاج .app مجلد مفكوك الضغط
//

import Foundation
import UIKit.UIApplication
import Zip
import ZIPFoundation
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
    @ObservedObject var viewModel: InstallerStatusViewModel
    
    private let _fileManager = FileManager.default
    private let _uuid = UUID().uuidString
    private var _payloadUrl: URL?
    
    private var _app: AppInfoPresentable
    private let _uniqueWorkDir: URL
    
    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
        self.viewModel = viewModel
        self._app = app
        self._uniqueWorkDir = _fileManager.temporaryDirectory
            .appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
        super.init()
    }
    
    func move() async throws {
        // Imported أو Signed مخزون كـ IPA → نفكه مؤقتاً
        if let ipaURL = _resolveIPA(), ipaURL.pathExtension.lowercased() == "ipa" {
            try await _extractPayloadFromIPA(ipaURL)
            return
        }
        
        // Signed قديم → .app مجلد
        guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
            throw SigningFileHandlerError.appNotFound
        }
        
        let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
        let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

        try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
        try _fileManager.copyItem(at: appUrl, to: movedAppURL)
        _payloadUrl = payloadUrl
    }
    
    func archive() async throws -> URL {
        // دائماً نضغط من _payloadUrl (المُستخرج في move())
        return try await Task.detached(priority: .background) { [self] in
            guard let payloadUrl = await self._payloadUrl else {
                throw SigningFileHandlerError.appNotFound
            }
            
            let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
            
            try await Zip.zipFiles(
                paths: [payloadUrl],
                zipFilePath: ipaUrl,
                password: nil,
                compression: ArchiveHandler.getCompressionLevel(),
                progress: { progress in
                    Task { @MainActor in
                        self.viewModel.packageProgress = progress
                    }
                })
            
            return ipaUrl
        }.value
    }
    
    func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
        let appendingString = "\(_app.name!)_\(_app.version!)_\(Int(Date().timeIntervalSince1970)).ipa"
        let dest = _fileManager.archives.appendingPathComponent(appendingString)
        
        try? _fileManager.moveItem(at: package, to: dest)
        
        if shouldOpen {
            await MainActor.run {
                UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
            }
        }
        
        return dest
    }
    
    /// يرجع مستوى الضغط الصحيح بناءً على rawValue المخزون في UserDefaults
    static func getCompressionLevel() -> ZipCompression {
        let stored = UserDefaults.standard.integer(forKey: "Feather.compressionLevel")
        // rawValue مباشرة من المكتبة — إذا ما لقى القيمة يرجع BestSpeed كافتراضي
        return ZipCompression(rawValue: stored) ?? .BestSpeed
    }
    
    // MARK: - يرجع IPA URL سواء كان Imported أو Signed
    private func _resolveIPA() -> URL? {
        if let imported = _app as? Imported { return imported.source }
        if let signed   = _app as? Signed   { return signed.source }
        return nil
    }
    
    // MARK: - استخراج Payload من IPA مؤقتاً (للـ Signing والـ Archive)
    private func _extractPayloadFromIPA(_ ipaURL: URL) async throws {
        try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
        
        guard let archive = try? Archive(url: ipaURL, accessMode: .read) else {
            throw SigningFileHandlerError.appNotFound
        }
        
        let payloadEntries = archive.filter { $0.path.hasPrefix("Payload/") }
        let totalEntries = max(payloadEntries.count, 1)
        var entryCount = 0
        
        for entry in archive {
            guard entry.path.hasPrefix("Payload/") else { continue }
            
            let destPath = _uniqueWorkDir.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try? _fileManager.createDirectory(at: destPath, withIntermediateDirectories: true)
            default:
                let parent = destPath.deletingLastPathComponent()
                try? _fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try? archive.extract(entry, to: destPath)
            }
            
            entryCount += 1
            let p = Double(entryCount) / Double(totalEntries) * 0.5
            await MainActor.run { self.viewModel.packageProgress = p }
        }
        
        _payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
    }
}
