//
//  SigningHandler.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//
//  MODIFIED: يدعم الآن التوقيع المباشر من IPA (للـ Imported apps)
//            بدل ما يحتاج .app مجلد مفكوك الضغط
//

import ZIPFoundation
import Zsign
import UIKit
import OSLog
import Zip

final class SigningHandler: NSObject {
    private let _fileManager = FileManager.default
    private let _uuid = UUID().uuidString
    private var _movedAppPath: URL?
    private var _app: AppInfoPresentable
    private var _options: Options
    private let _uniqueWorkDir: URL
    
    var appIcon: UIImage?
    var appCertificate: CertificatePair?
    
    init(app: AppInfoPresentable, options: Options = OptionsManager.shared.options) {
        self._app = app
        self._options = options
        self._uniqueWorkDir = _fileManager.temporaryDirectory
            .appendingPathComponent("FeatherSigning_\(_uuid)", isDirectory: true)
        super.init()
    }
    
    func copy() async throws {
        try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
        
        let appUrl = try _resolveAppURL()
        let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)
        
        print(appUrl)
        print(movedAppURL)
        
        try _fileManager.copyItem(at: appUrl, to: movedAppURL)
        _movedAppPath = movedAppURL
        print("[\(_uuid)] Moved Payload to: \(movedAppURL.path)")
    }
    
    func modify() async throws {
        guard let movedAppPath = _movedAppPath else {
            throw SigningFileHandlerError.appNotFound
        }
        
        guard
            let infoDictionary = NSDictionary(
                contentsOf: movedAppPath.appendingPathComponent("Info.plist")
            )!.mutableCopy() as? NSMutableDictionary
        else {
            throw SigningFileHandlerError.infoPlistNotFound
        }
        
        try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)
        
        if let icon = appIcon {
            try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
        }
        
        if let name = _options.appName {
            try await _modifyLocalesForName(name, for: movedAppPath)
        }
        
        if _options.removeWatchPlaceholder {
            try await _removePlaceholderWatch(for: movedAppPath)
        }
        
        if !_options.removeFiles.isEmpty {
            try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
        }
        
        try await _removeCodeSignature(for: movedAppPath)
        try await _removeProvisioning(for: movedAppPath)
        
        try await _inject(for: movedAppPath, with: _options.injectionFiles, with: _options)
        
        if _options.experiment_supportLiquidGlass {
            try await _locateMachosAndChangeToSDK26(for: movedAppPath)
        }
        
        if !_options.injectionFiles.isEmpty {
            try await _inject(for: movedAppPath, with: _options.injectionFiles, with: _options)
        }
        
        if _options.experiment_replaceSubstrateWithEllekit {
            // إعادة الحقن لاستبدال Substrate بـ ElleKit
            try await _inject(for: movedAppPath, with: _options.injectionFiles, with: _options)
        }
        
        if #available(iOS 19, *) {
            try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)
        }
        
        let handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)
        try await handler.disinject()
        
        if !_options.onlyModify {
            let handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)
            
            if _options.doAdhocSigning {
                try await handler.adhocSign()
            } else if (appCertificate != nil) {
                try await handler.sign()
            } else {
                throw SigningFileHandlerError.missingCertifcate
            }
        }
        try await self.move()
        try await self.addToDatabase()

        if let error = handler.hadError {
            throw error
        }
    }
    
    func move() async throws {
        guard let movedAppPath = _movedAppPath else {
            throw SigningFileHandlerError.appNotFound
        }
        
        let destDir = try await _directory()
        try _fileManager.createDirectoryIfNeeded(at: destDir)
        
        // نضغط الـ .app داخل Payload ونحفظه كـ IPA
        let appName = movedAppPath.deletingPathExtension().lastPathComponent
        let ipaURL = destDir.appendingPathComponent("\(appName).ipa")
        
        try await Task.detached(priority: .background) { [self] in
            // Payload/ مباشرة داخل workDir بدون مجلد وسيط
            let payloadDir = self._uniqueWorkDir.appendingPathComponent("Payload")
            try self._fileManager.createDirectoryIfNeeded(at: payloadDir)
            let appInPayload = payloadDir.appendingPathComponent(movedAppPath.lastPathComponent)
            try self._fileManager.moveItem(at: movedAppPath, to: appInPayload)
            
            // نضغط Payload/ مباشرة → البنية الصحيحة: Payload/App.app
            try Zip.zipFiles(
                paths: [payloadDir],
                zipFilePath: ipaURL,
                password: nil,
                compression: ArchiveHandler.getCompressionLevel(),
                progress: nil
            )
            
            try? self._fileManager.removeItem(at: payloadDir)
        }.value
        
        print("[\(_uuid)] Saved signed IPA at: \(ipaURL.path)")
        _movedAppPath = ipaURL
        try? _fileManager.removeItem(at: _uniqueWorkDir)
    }
    
    func addToDatabase() async throws {
        let destDir = try await _directory()
        
        // نبحث عن الـ IPA في مجلد UUID
        guard let ipaUrl = _fileManager.getPath(in: destDir, for: "ipa") else {
            return
        }
        
        // نستخرج المعلومات من الـ IPA مباشرة
        var appName: String?
        var appIdentifier: String?
        var appVersion: String?
        var appIcon: String?
        
        if let archive = Archive(url: ipaUrl, accessMode: .read),
           let infoPlistEntry = archive.first(where: {
               $0.path.hasPrefix("Payload/") &&
               $0.path.hasSuffix(".app/Info.plist") &&
               $0.path.components(separatedBy: "/").count == 3
           }) {
            var plistData = Data()
            _ = try? archive.extract(infoPlistEntry, consumer: { plistData.append($0) })
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                appName       = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
                appIdentifier = plist["CFBundleIdentifier"] as? String
                appVersion    = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
                
                let appPath = infoPlistEntry.path.components(separatedBy: "/").prefix(2).joined(separator: "/")
                
                // نجمع كل أسماء الأيقونات الممكنة من كل المفاتيح
                var iconCandidateNames: [String] = []
                
                // CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles
                if let icons = plist["CFBundleIcons"] as? [String: Any],
                   let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                   let files = primary["CFBundleIconFiles"] as? [String] {
                    iconCandidateNames.append(contentsOf: files.reversed())
                }
                // CFBundleIcons~ipad
                if let icons = plist["CFBundleIcons~ipad"] as? [String: Any],
                   let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                   let files = primary["CFBundleIconFiles"] as? [String] {
                    iconCandidateNames.append(contentsOf: files.reversed())
                }
                // CFBundleIconFiles مباشرة (تطبيقات قديمة)
                if let files = plist["CFBundleIconFiles"] as? [String] {
                    iconCandidateNames.append(contentsOf: files.reversed())
                }
                // CFBundleIconName
                if let name = plist["CFBundleIconName"] as? String {
                    iconCandidateNames.append(name)
                }
                
                let suffixes = ["@3x.png", "@2x.png", ".png", ""]
                
                outer: for iconName in iconCandidateNames {
                    for suffix in suffixes {
                        let candidate = "\(appPath)/\(iconName)\(suffix)"
                        if let entry = archive.first(where: { $0.path == candidate }) {
                            let iconFileName = "\(iconName)\(suffix)"
                            var iconData = Data()
                            _ = try? archive.extract(entry, consumer: { iconData.append($0) })
                            let iconDest = destDir.appendingPathComponent(iconFileName)
                            try? iconData.write(to: iconDest)
                            appIcon = iconFileName
                            break outer
                        }
                    }
                }
                
                // fallback: أي png يشبه أيقونة في الـ .app
                if appIcon == nil {
                    if let entry = archive.first(where: {
                        $0.path.hasPrefix("\(appPath)/") &&
                        $0.path.lowercased().contains("icon") &&
                        $0.path.hasSuffix(".png")
                    }) {
                        let iconFileName = URL(fileURLWithPath: entry.path).lastPathComponent
                        var iconData = Data()
                        _ = try? archive.extract(entry, consumer: { iconData.append($0) })
                        let iconDest = destDir.appendingPathComponent(iconFileName)
                        try? iconData.write(to: iconDest)
                        appIcon = iconFileName
                    }
                }
            }
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Storage.shared.addSigned(
                uuid: _uuid,
                source: ipaUrl,
                certificate: _options.doAdhocSigning ? nil : appCertificate,
                appName: appName,
                appIdentifier: appIdentifier,
                appVersion: appVersion,
                appIcon: appIcon
            ) { _ in
                Logger.signing.info("[\(self._uuid)] Added to database")
                continuation.resume()
            }
        }
    }
    
    private func _directory() async throws -> URL {
        // Documents/App/Signed/\(UUID)
        _fileManager.signed(_uuid)
    }
    
    func clean() async throws {
        try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
    }
    
    // MARK: - IPA extraction support
    
    /// يحلّ مسار الـ .app:
    /// - إذا كان Imported (source = IPA): يفك الضغط مؤقتاً ويرجع الـ .app
    /// - إذا كان Signed (مجلد .app موجود): يرجعه مباشرة
    private func _resolveAppURL() throws -> URL {
        // Imported → source هو IPA مباشرة
        if let imported = _app as? Imported, let ipaURL = imported.source {
            return try _extractAppFromIPA(ipaURL)
        }
        // Signed → أولاً نشوف لو عنده IPA (جديد)
        if let signed = _app as? Signed, let ipaURL = signed.source,
           ipaURL.pathExtension.lowercased() == "ipa" {
            return try _extractAppFromIPA(ipaURL)
        }
        // Signed → fallback للـ .app القديم
        guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
            throw SigningFileHandlerError.appNotFound
        }
        return appUrl
    }
    
    /// يفك ضغط الـ IPA مؤقتاً في _uniqueWorkDir ويرجع مسار الـ .app
    private func _extractAppFromIPA(_ ipaURL: URL) throws -> URL {
        let extractDir = _uniqueWorkDir.appendingPathComponent("_extracted")
        try _fileManager.createDirectoryIfNeeded(at: extractDir)
        
        // نستخدم ZIPFoundation لفك الضغط
        guard let archive = try? Archive(url: ipaURL, accessMode: .read) else {
            throw SigningFileHandlerError.appNotFound
        }
        
        for entry in archive {
            // نفك فقط Payload/AppName.app/** 
            guard entry.path.hasPrefix("Payload/") else { continue }
            
            let destPath = extractDir.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try? _fileManager.createDirectory(at: destPath, withIntermediateDirectories: true)
            default:
                let parent = destPath.deletingLastPathComponent()
                try? _fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try? archive.extract(entry, to: destPath)
            }
        }
        
        // ابحث عن .app داخل Payload/
        let payloadDir = extractDir.appendingPathComponent("Payload")
        guard let appURL = _fileManager.getPath(in: payloadDir, for: "app") else {
            throw SigningFileHandlerError.appNotFound
        }
        
        return appURL
    }
}

extension SigningHandler {
    private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
        if options.fileSharing { infoDictionary.setObject(true, forKey: "UISupportsDocumentBrowser" as NSCopying) }
        if options.itunesFileSharing { infoDictionary.setObject(true, forKey: "UIFileSharingEnabled" as NSCopying) }
        if options.proMotion { infoDictionary.setObject(true, forKey: "CADisableMinimumFrameDurationOnPhone" as NSCopying) }
        if options.gameMode { infoDictionary.setObject(true, forKey: "GCSupportsGameMode" as NSCopying)}
        if options.ipadFullscreen { infoDictionary.setObject(true, forKey: "UIRequiresFullScreen" as NSCopying) }
        if options.removeSupportedDevices { infoDictionary.removeObject(forKey: "UISupportedDevices") }
        if options.removeURLScheme { infoDictionary.removeObject(forKey: "CFBundleURLTypes") }
        
        if options.appAppearance != Options.defaultOptions.appAppearance {
            infoDictionary.setObject(options.appAppearance, forKey: "UIUserInterfaceStyle" as NSCopying)
        }
        if options.minimumAppRequirement != Options.defaultOptions.minimumAppRequirement {
            infoDictionary.setObject(options.minimumAppRequirement, forKey: "MinimumOSVersion" as NSCopying)
        }
        
        if options.onlyModify {
            if let customIdentifier = options.appIdentifier {
                infoDictionary.setObject(customIdentifier, forKey: "CFBundleIdentifier" as NSCopying)
            }
            if let customName = options.appName {
                infoDictionary.setObject(customName, forKey: "CFBundleDisplayName" as NSCopying)
                infoDictionary.setObject(customName, forKey: "CFBundleName" as NSCopying)
            }
            if let customVersion = options.appVersion {
                infoDictionary.setObject(customVersion, forKey: "CFBundleShortVersionString" as NSCopying)
                infoDictionary.setObject(customVersion, forKey: "CFBundleVersion" as NSCopying)
            }
        }
        
        try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
    }
    
    private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
        let imageSizes = [
            (width: 120, height: 120, name: "FRIcon60x60@2x.png"),
            (width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
        ]
        
        for imageSize in imageSizes {
            let resizedImage = image.resize(imageSize.width, imageSize.height)
            let imageData = resizedImage.pngData()
            let fileURL = app.appendingPathComponent(imageSize.name)
            try imageData?.write(to: fileURL)
        }
        
        let cfBundleIcons: [String: Any] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["FRIcon60x60"],
                "CFBundleIconName": "FRIcon"
            ]
        ]
        
        let cfBundleIconsIpad: [String: Any] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
                "CFBundleIconName": "FRIcon"
            ]
        ]
        
        infoDictionary["CFBundleIcons"] = cfBundleIcons
        infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
        
        try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
    }
    
    private func _removePlaceholderWatch(for app: URL) async throws {
        let path = app.appendingPathComponent("com.apple.WatchPlaceholder")
        try _fileManager.removeFileIfNeeded(at: path)
    }
    
    private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
        let filesToRemove = appendingComponent.map { app.appendingPathComponent($0) }
        for url in filesToRemove {
            try _fileManager.removeFileIfNeeded(at: url)
        }
    }
    
    private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
        let localizationBundles = try _fileManager
            .contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        
        localizationBundles.forEach { bundleURL in
            let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
            guard
                _fileManager.fileExists(atPath: plistURL.path),
                let dictionary = NSMutableDictionary(contentsOf: plistURL)
            else { return }
            
            dictionary["CFBundleDisplayName"] = name
            dictionary.write(toFile: plistURL.path, atomically: true)
        }
    }
    
    private func _removeCodeSignature(for app: URL) async throws {
        let provisioningFilePath = app.appendingPathComponent("_CodeSignature")
        try _fileManager.removeFileIfNeeded(at: provisioningFilePath)
    }
    
    private func _removeProvisioning(for app: URL) async throws {
        let provisioningFilePath = app.appendingPathComponent("embedded.mobileprovision")
        try _fileManager.removeFileIfNeeded(at: provisioningFilePath)
    }
    
    private func _inject(for app: URL, with tweaks: [URL], with options: Options) async throws {
        let handler = TweakHandler(app: app, with: tweaks, options: options)
        do {
            try await handler.getInputFiles()
        } catch {
            throw error
        }
    }
    
    private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
        if let url = Bundle(url: app)?.executableURL {
            LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
        }
    }
    
    @available(iOS 19, *)
    private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
        let machoFiles = _enumerateFiles(at: app) {
            $0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
        }
        
        for fileURL in machoFiles {
            switch fileURL.pathExtension {
            case "dylib":
                LCPatchMachOFixupARM64eSlice(fileURL.path)
            case "framework":
                if
                    let bundle = Bundle(url: fileURL),
                    let execURL = bundle.executableURL
                {
                    LCPatchMachOFixupARM64eSlice(execURL.path)
                }
            default:
                continue
            }
        }
    }
    
    private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
        guard let fileEnum = _fileManager.enumerator(atPath: base.path) else { return [] }
        var results: [URL] = []
        while let file = fileEnum.nextObject() as? String {
            if predicate(file) {
                results.append(base.appendingPathComponent(file))
            }
        }
        return results
    }
}

enum SigningFileHandlerError: Error, LocalizedError {
    case appNotFound
    case infoPlistNotFound
    case missingCertifcate
    case disinjectFailed
    case signFailed
    
    var errorDescription: String? {
        switch self {
        case .appNotFound:
            return "Unable to locate bundle path."
        case .infoPlistNotFound:
            return "Unable to locate info.plist path."
        case .missingCertifcate:
            return "No certificate was specified."
        case .disinjectFailed:
            return "Removing mach-O load paths failed."
        case .signFailed:
            return "Signing failed."
        }
    }
}
