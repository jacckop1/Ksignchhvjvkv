//
//  CertificateInjectView.swift
//  Ksign
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import ZIPFoundation
import Zip
import CryptoKit

// MARK: - Injection Method
enum InjectionMethod: String, CaseIterable {
    case zip          = "zip"
    case p12Provision = "p12+mobileprovision"
}

struct CertificateInjectView: View {
    @Environment(\.dismiss) private var dismiss

    var app: AppInfoPresentable
    var onInjectComplete: () -> Void

    // MARK: - Common States
    @State private var _isWorking = false
    @State private var _errorMessage: String = ""
    @State private var _isErrorPresenting = false
    @State private var _existingFolderName: String = ""
    @State private var _hasSigningAssets: Bool = false
    @State private var _certFolderName: String = ""

    // MARK: - ZIP Method States
    @State private var _zipURL: URL? = nil
    @State private var _isImportingZip = false
    @State private var _zipPassword: String = ""
    @State private var _zipPasswordLoaded = false

    // MARK: - P12+Provision Method States
    @State private var _showP12ProvisionSection = false
    @State private var _p12URL: URL? = nil
    @State private var _provisionURL: URL? = nil
    @State private var _p12Password: String = ""
    @State private var _isImportingP12 = false
    @State private var _isImportingProvision = false

    // MARK: Body
    var body: some View {
        NBNavigationView(.localized("حقن الشهادة"), displayMode: .inline) {
            Form {
                // ── معلومات التطبيق ──────────────────────────────────
                Section {
                    HStack(spacing: 12) {
                        FRAppIconView(app: app, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name ?? "Unknown")
                                .font(.headline)
                            Text(app.identifier ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // ── حالة signing-assets ──────────────────────────────
                Section {
                    HStack {
                        Image(systemName: _hasSigningAssets ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(_hasSigningAssets ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(_hasSigningAssets
                                 ? "مجلد الشهادات موجود"
                                 : "مجلد الشهادات غير موجود")
                                .font(.subheadline)
                            if _hasSigningAssets && !_existingFolderName.isEmpty {
                                Text("الشهادة الحالية: \(_existingFolderName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("فحص التطبيق")
                }

                // ── اسم مجلد الشهادة ─────────────────────────────────
                Section {
                    TextField("اسم مجلد الشهادة", text: $_certFolderName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("اسم الشهادة")
                }

                // ── قسم ZIP ──────────────────────────────────────────
                NBSection("إضافة ZIP") {
                    Button {
                        _isImportingZip = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.zipper")
                            Text(_zipURL == nil ? "رفع ملف ZIP" : _zipURL!.lastPathComponent)
                                .foregroundColor(_zipURL == nil ? .accentColor : .primary)
                        }
                    }
                    .disabled(_zipURL != nil)

                    if _zipURL != nil {
                        Button(role: .destructive) {
                            _zipURL = nil
                            _zipPassword = ""
                            _zipPasswordLoaded = false
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("إزالة الملف")
                            }
                        }

                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.purple)
                            TextField("كلمة سر الشهادة", text: $_zipPassword)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                } footer: {
                    Text("ملف ZIP يحتوي على: cert.p12، cert.mobileprovision، cert.txt (كلمة السر)")
                }

                // زر حقن ZIP
                if _zipURL != nil {
                    Section {
                        _injectButton(label: "حقن عبر ZIP") {
                            Task { await _injectViaZip() }
                        }
                        .disabled(!_canInjectZip || _isWorking)
                    }
                }

                // ── قسم p12+mobileprovision ───────────────────────────
                Section {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            _showP12ProvisionSection.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: _showP12ProvisionSection
                                  ? "chevron.up.circle.fill"
                                  : "chevron.down.circle")
                                .foregroundColor(.accentColor)
                            Text("p12 + mobileprovision")
                                .foregroundColor(.primary)
                            Spacer()
                            if _p12URL != nil || _provisionURL != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if _showP12ProvisionSection {
                        Button {
                            _isImportingP12 = true
                        } label: {
                            HStack {
                                Image(systemName: "key.fill")
                                    .foregroundColor(.orange)
                                Text(_p12URL == nil ? "إضافة ملف .p12" : _p12URL!.lastPathComponent)
                                    .foregroundColor(_p12URL == nil ? .accentColor : .primary)
                                Spacer()
                                if _p12URL != nil {
                                    Button(role: .destructive) { _p12URL = nil } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .disabled(_p12URL != nil)

                        Button {
                            _isImportingProvision = true
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.gearshape.fill")
                                    .foregroundColor(.blue)
                                Text(_provisionURL == nil ? "إضافة ملف .mobileprovision" : _provisionURL!.lastPathComponent)
                                    .foregroundColor(_provisionURL == nil ? .accentColor : .primary)
                                Spacer()
                                if _provisionURL != nil {
                                    Button(role: .destructive) { _provisionURL = nil } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .disabled(_provisionURL != nil)

                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.purple)
                            SecureField("كلمة سر الشهادة (.p12)", text: $_p12Password)
                                .textContentType(.oneTimeCode)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                } header: {
                    Text("إضافة ملفات الشهادة")
                } footer: {
                    if _showP12ProvisionSection {
                        Text("اختر ملف .p12 وملف .mobileprovision ثم أدخل كلمة السر. سيتم إنشاء cert.txt تلقائياً.")
                    }
                }

                // زر حقن p12+provision
                if _showP12ProvisionSection && (_p12URL != nil || _provisionURL != nil) {
                    Section {
                        _injectButton(label: "حقن عبر p12+mobileprovision") {
                            Task { await _injectViaP12Provision() }
                        }
                        .disabled(!_canInjectP12 || _isWorking)
                    }
                }
            }
            .toolbar {
                NBToolbarButton(role: .cancel)
            }
            // ── File Importers ────────────────────────────────────────
            .sheet(isPresented: $_isImportingZip) {
                FileImporterRepresentableView(
                    allowedContentTypes: [UTType.zip],
                    onDocumentsPicked: { urls in
                        guard let url = urls.first else { return }
                        _zipURL = url
                        // نحاول نستخرج الباسورد من txt داخل ZIP تلقائياً
                        if let archive = Archive(url: url, accessMode: .read) {
                            for entry in archive where entry.type == .file {
                                let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
                                if name.hasSuffix(".txt") {
                                    var data = Data()
                                    _ = try? archive.extract(entry, consumer: { data.append($0) })
                                    if let txt = String(data: data, encoding: .utf8)?
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                       !txt.isEmpty {
                                        _zipPassword = txt
                                        _zipPasswordLoaded = true
                                    }
                                    break
                                }
                            }
                        }
                    }
                )
            }
            .sheet(isPresented: $_isImportingP12) {
                FileImporterRepresentableView(
                    allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data],
                    onDocumentsPicked: { urls in
                        guard let url = urls.first else { return }
                        _p12URL = url
                    }
                )
            }
            .sheet(isPresented: $_isImportingProvision) {
                FileImporterRepresentableView(
                    allowedContentTypes: [UTType(filenameExtension: "mobileprovision") ?? .data],
                    onDocumentsPicked: { urls in
                        guard let url = urls.first else { return }
                        _provisionURL = url
                    }
                )
            }
            .alert("خطأ", isPresented: $_isErrorPresenting) {
                Button("موافق", role: .cancel) {}
            } message: {
                Text(_errorMessage)
            }
            .onAppear {
                _checkSigningAssets()
            }
        }
    }

    // MARK: - Shared Inject Button
    @ViewBuilder
    private func _injectButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Spacer()
                if _isWorking {
                    ProgressView().padding(.trailing, 6)
                    Text("جاري الحقن...")
                } else {
                    Image(systemName: "syringe")
                    Text(label)
                }
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.vertical, 6)
            .background(_isWorking ? Color.gray : Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: - Computed Flags
    private var _canInjectZip: Bool {
        _zipURL != nil && _hasSigningAssets
    }
    private var _canInjectP12: Bool {
        _p12URL != nil && _provisionURL != nil && !_p12Password.isEmpty && _hasSigningAssets
    }
}

// MARK: - Logic
extension CertificateInjectView {

    // ─────────────────────────────────────────────────────────────
    // MARK: فحص signing-assets
    // ─────────────────────────────────────────────────────────────
    private func _checkSigningAssets() {
        guard let ipaURL = _resolveIPA() else { return }

        Task.detached(priority: .background) {
            guard let archive = Archive(url: ipaURL, accessMode: .read) else { return }

            var foundSigningAssets = false
            var foundFolder = ""

            for entry in archive {
                let path = entry.path
                let normalised = path.replacingOccurrences(of: "\\", with: "/")
                let lc = normalised.lowercased()

                let isSigningAssetsDir = lc.contains("/signing-assets/") ||
                                         lc.hasSuffix("/signing-assets") ||
                                         lc == "signing-assets/" ||
                                         lc == "signing-assets"

                if isSigningAssetsDir {
                    foundSigningAssets = true
                }

                let components = normalised.components(separatedBy: "/")
                if let sigIdx = components.firstIndex(where: {
                    $0.lowercased() == "signing-assets"
                }) {
                    let next = sigIdx + 1
                    if next < components.count {
                        let candidate = components[next]
                        if !candidate.isEmpty && candidate != ".keep" {
                            let isDir = entry.type == .directory
                            let hasDeeper = next + 1 < components.count
                            if isDir || hasDeeper {
                                foundFolder = candidate
                            }
                        }
                    }
                }

                if foundSigningAssets && !foundFolder.isEmpty { break }
            }

            await MainActor.run {
                _hasSigningAssets = foundSigningAssets
                _existingFolderName = foundFolder
                if _certFolderName.isEmpty {
                    _certFolderName = foundFolder
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: حقن عبر ZIP
    // ─────────────────────────────────────────────────────────────
    @MainActor
    private func _injectViaZip() async {
        guard let ipaURL = _resolveIPA(), let zipURL = _zipURL else { return }
        _isWorking = true
        defer { _isWorking = false }

        let passwordOverride = _zipPassword

        do {
            let certFolderName    = _certFolderName
            let existingFolderName = _existingFolderName
            let originalAppName   = app.name ?? "App"

            let result = try await Task.detached(priority: .background) {
                try Self._performInject(
                    ipaURL: ipaURL,
                    source: .zip(zipURL, passwordOverride: passwordOverride.isEmpty ? nil : passwordOverride),
                    newFolderName: certFolderName,
                    oldFolderName: existingFolderName,
                    originalAppName: originalAppName
                )
            }.value

            await _addInjectedAsNew(injectedIPA: result.ipa, injectedName: result.injectedName)
            let folderName = _certFolderName.isEmpty ? _existingFolderName : _certFolderName
            await _registerCertificate(p12Data: result.p12, provisionData: result.provision,
                                        password: result.password, name: folderName)
            dismiss()
            onInjectComplete()
        } catch {
            _errorMessage = error.localizedDescription
            _isErrorPresenting = true
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: حقن عبر p12 + mobileprovision
    // ─────────────────────────────────────────────────────────────
    @MainActor
    private func _injectViaP12Provision() async {
        guard let ipaURL      = _resolveIPA(),
              let p12URL      = _p12URL,
              let provisionURL = _provisionURL else { return }
        _isWorking = true
        defer { _isWorking = false }

        let password           = _p12Password
        let certFolderName    = _certFolderName
        let existingFolderName = _existingFolderName
        let originalAppName   = app.name ?? "App"

        do {
            let result = try await Task.detached(priority: .background) {
                try Self._performInject(
                    ipaURL: ipaURL,
                    source: .files(p12: p12URL, provision: provisionURL, password: password),
                    newFolderName: certFolderName,
                    oldFolderName: existingFolderName,
                    originalAppName: originalAppName
                )
            }.value

            await _addInjectedAsNew(injectedIPA: result.ipa, injectedName: result.injectedName)
            let folderName = _certFolderName.isEmpty ? _existingFolderName : _certFolderName
            await _registerCertificate(p12Data: result.p12, provisionData: result.provision,
                                        password: result.password, name: folderName)
            dismiss()
            onInjectComplete()
        } catch {
            _errorMessage = error.localizedDescription
            _isErrorPresenting = true
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: تسجيل الشهادة في CoreData
    // ─────────────────────────────────────────────────────────────
    private func _registerCertificate(p12Data: Data, provisionData: Data,
                                       password: String, name: String) async {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("KsignCertReg_\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let p12URL = tmpDir.appendingPathComponent("cert.p12")
        let provisionURL = tmpDir.appendingPathComponent("cert.mobileprovision")
        try? p12Data.write(to: p12URL)
        try? provisionData.write(to: provisionURL)

        await withCheckedContinuation { continuation in
            FR.handleCertificateFiles(
                p12URL: p12URL,
                provisionURL: provisionURL,
                p12Password: password,
                certificateName: name
            ) { _ in
                try? fm.removeItem(at: tmpDir)
                continuation.resume()
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: إضافة IPA المحقون كتطبيق جديد في المكتبة
    // ─────────────────────────────────────────────────────────────
    private func _addInjectedAsNew(injectedIPA: URL, injectedName: String) async {
        let fm = FileManager.default
        let renamedIPA = injectedIPA.deletingLastPathComponent()
            .appendingPathComponent("\(injectedName).ipa")
        try? fm.moveItem(at: injectedIPA, to: renamedIPA)

        await withCheckedContinuation { continuation in
            FR.handlePackageFile(renamedIPA) { _ in
                continuation.resume()
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: منطق الحقن الرئيسي
    // ─────────────────────────────────────────────────────────────
    private enum InjectSource {
        case zip(URL, passwordOverride: String?)
        case files(p12: URL, provision: URL, password: String)
    }

    private static func _performInject(
        ipaURL: URL,
        source: InjectSource,
        newFolderName: String,
        oldFolderName: String,
        originalAppName: String
    ) throws -> (ipa: URL, p12: Data, provision: Data, password: String, injectedName: String) {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("KsignInject_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpDir) }
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // ── استخراج بيانات الشهادة ──────────────────────────────
        let p12Data: Data
        let provisionData: Data
        let password: String

        switch source {
        case .zip(let zipURL, let passwordOverride):
            guard let zipArchive = Archive(url: zipURL, accessMode: .read) else {
                throw InjectError.invalidZip
            }
            var _p12: Data?; var _prov: Data?; var _pass: String?
            for entry in zipArchive where entry.type == .file {
                var data = Data()
                _ = try? zipArchive.extract(entry, consumer: { data.append($0) })
                let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
                if name.hasSuffix(".p12")                 { _p12  = data }
                else if name.hasSuffix(".mobileprovision") { _prov = data }
                else if name.hasSuffix(".txt")             {
                    _pass = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard let p = _p12, let v = _prov else {
                throw InjectError.missingFilesInZip
            }
            p12Data = p; provisionData = v
            // passwordOverride (من حقل UI) يأخذ الأولوية، ثم txt من ZIP، ثم فارغ
            password = passwordOverride ?? _pass ?? ""

        case .files(let p12URL, let provisionURL, let pass):
            p12Data       = try Data(contentsOf: p12URL)
            provisionData = try Data(contentsOf: provisionURL)
            password      = pass
        }

        // ── فك ضغط IPA ──────────────────────────────────────────
        let ipaExtract = tmpDir.appendingPathComponent("ipa_extracted")
        try fm.createDirectory(at: ipaExtract, withIntermediateDirectories: true)

        guard let ipaArchive = Archive(url: ipaURL, accessMode: .read) else {
            throw InjectError.invalidIPA
        }
        for entry in ipaArchive {
            let dest = ipaExtract.appendingPathComponent(entry.path)
            switch entry.type {
            case .directory:
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            default:
                try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? ipaArchive.extract(entry, to: dest)
            }
        }

        // ── إيجاد .app داخل Payload ──────────────────────────────
        guard let payloadDir = fm.getPath(in: ipaExtract.appendingPathComponent("Payload"),
                                          for: "app") else {
            throw InjectError.invalidIPA
        }

        // ── إيجاد signing-assets ─────────────────────────────────
        let signingAssetsDir = try _findSigningAssetsDir(in: payloadDir)

        // ── تحديد اسم المجلد الجديد ──────────────────────────────
        let folderName = newFolderName.isEmpty
            ? (oldFolderName.isEmpty ? "certificate" : oldFolderName)
            : newFolderName

        // ── حذف كل محتوى signing-assets ──────────────────────────
        if let contents = try? fm.contentsOfDirectory(
            at: signingAssetsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) {
            for item in contents { try? fm.removeItem(at: item) }
        }

        // ── إنشاء مجلد الشهادة الجديد ────────────────────────────
        let certDir = signingAssetsDir.appendingPathComponent(folderName)
        try fm.createDirectory(at: certDir, withIntermediateDirectories: true)

        let certP12Path        = certDir.appendingPathComponent("cert.p12")
        let certProvisionPath  = certDir.appendingPathComponent("cert.mobileprovision")
        let certTxtPath        = certDir.appendingPathComponent("cert.txt")

        try p12Data.write(to: certP12Path)
        try provisionData.write(to: certProvisionPath)
        // cert.txt: كلمة السر بدون newline (مطابق لـ IPA2)
        try password.data(using: .utf8)!.write(to: certTxtPath)

        // ── كتابة embedded.mobileprovision في جذر .app ───────────
        // (نسخة مطابقة تماماً من cert.mobileprovision)
        let embeddedProvisionPath = payloadDir.appendingPathComponent("embedded.mobileprovision")
        try provisionData.write(to: embeddedProvisionPath)

        // ── تحديث _CodeSignature/CodeResources ───────────────────
        // هذا الجزء يحدّث هاشات الملفات المتغيرة فقط دون المساس بأي شيء آخر
        let codeResourcesPath = payloadDir
            .appendingPathComponent("_CodeSignature")
            .appendingPathComponent("CodeResources")

        if fm.fileExists(atPath: codeResourcesPath.path) {
            try _updateCodeResources(
                at: codeResourcesPath,
                oldFolderName: oldFolderName,
                newFolderName: folderName,
                p12Data: p12Data,
                provisionData: provisionData,
                passwordData: password.data(using: .utf8)!
            )
        }

        // ── إعادة الضغط كـ IPA ───────────────────────────────────
        let payloadWrap = tmpDir.appendingPathComponent("wrap")
        try fm.createDirectory(at: payloadWrap, withIntermediateDirectories: true)

        let wrapPayload = payloadWrap.appendingPathComponent("Payload")
        try fm.createDirectory(at: wrapPayload, withIntermediateDirectories: true)
        try fm.copyItem(at: payloadDir,
                        to: wrapPayload.appendingPathComponent(payloadDir.lastPathComponent))

        let newIPA = tmpDir.appendingPathComponent("injected.ipa")

        let contentsOfWrap = try fm.contentsOfDirectory(
            at: payloadWrap,
            includingPropertiesForKeys: nil
        )
        try Zip.zipFiles(
            paths: contentsOfWrap,
            zipFilePath: newIPA,
            password: nil,
            compression: .DefaultCompression,
            progress: { _ in }
        )

        let finalIPA = fm.temporaryDirectory
            .appendingPathComponent("KsignInjected_\(UUID().uuidString).ipa")
        try fm.moveItem(at: newIPA, to: finalIPA)

        let injectedName = "\(originalAppName) (injected)"
        return (ipa: finalIPA, p12: p12Data, provision: provisionData,
                password: password, injectedName: injectedName)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: تحديث _CodeSignature/CodeResources
    // يحدّث هاشات الملفات المتغيرة فقط (signing-assets + embedded.mobileprovision)
    // دون المساس بأي توقيعات أخرى
    // ─────────────────────────────────────────────────────────────
    private static func _updateCodeResources(
        at url: URL,
        oldFolderName: String,
        newFolderName: String,
        p12Data: Data,
        provisionData: Data,
        passwordData: Data
    ) throws {
        guard var cr = try? Data(contentsOf: url),
              var plist = try? PropertyListSerialization.propertyList(
                  from: cr,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return }

        // حساب الهاشات
        let sha1  = { (d: Data) -> Data in Data(Insecure.SHA1.hash(data: d)) }
        let sha256 = { (d: Data) -> Data in Data(SHA256.hash(data: d)) }

        let provSHA1   = sha1(provisionData)
        let provSHA256 = sha256(provisionData)
        let p12SHA1    = sha1(p12Data)
        let p12SHA256  = sha256(p12Data)
        let txtSHA1    = sha1(passwordData)
        let txtSHA256  = sha256(passwordData)

        // المفاتيح القديمة والجديدة
        let oldPrefix = oldFolderName.isEmpty ? "" : "signing-assets/\(oldFolderName)/"
        let newPrefix = "signing-assets/\(newFolderName)/"

        let fileMapping: [(String, Data, Data)] = [
            (newPrefix + "cert.mobileprovision", provSHA1, provSHA256),
            (newPrefix + "cert.p12",             p12SHA1,  p12SHA256),
            (newPrefix + "cert.txt",             txtSHA1,  txtSHA256),
            ("embedded.mobileprovision",          provSHA1, provSHA256),
        ]

        // ── تحديث files (v1 - SHA1 فقط) ─────────────────────────
        if var files = plist["files"] as? [String: Any] {
            // حذف المفاتيح القديمة لـ signing-assets
            let oldKeys = files.keys.filter { $0.hasPrefix("signing-assets/") }
            for k in oldKeys { files.removeValue(forKey: k) }
            // إضافة المفاتيح الجديدة
            for (key, sha1Hash, _) in fileMapping {
                files[key] = sha1Hash
            }
            plist["files"] = files
        }

        // ── تحديث files2 (v2 - SHA1 + SHA256) ────────────────────
        if var files2 = plist["files2"] as? [String: Any] {
            // حذف المفاتيح القديمة لـ signing-assets
            let oldKeys = files2.keys.filter { $0.hasPrefix("signing-assets/") }
            for k in oldKeys { files2.removeValue(forKey: k) }
            // إضافة المفاتيح الجديدة
            for (key, sha1Hash, sha256Hash) in fileMapping {
                files2[key] = ["hash": sha1Hash, "hash2": sha256Hash]
            }
            plist["files2"] = files2
        }

        // كتابة الـ plist المحدّث
        let updated = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try updated.write(to: url)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: إيجاد signing-assets
    // ─────────────────────────────────────────────────────────────
    private static func _findSigningAssetsDir(in appDir: URL) throws -> URL {
        let fm = FileManager.default

        let direct = appDir.appendingPathComponent("signing-assets")
        if fm.fileExists(atPath: direct.path) { return direct }

        let enumerator = fm.enumerator(
            at: appDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            if url.lastPathComponent.lowercased() == "signing-assets" { return url }
        }

        throw InjectError.noSigningAssets
    }

    private func _resolveIPA() -> URL? {
        if let imported = app as? Imported { return imported.source }
        if let signed   = app as? Signed   { return signed.source }
        return nil
    }
}

// MARK: - Errors
enum InjectError: LocalizedError {
    case invalidZip
    case invalidIPA
    case missingFilesInZip
    case noSigningAssets

    var errorDescription: String? {
        switch self {
        case .invalidZip:        return "ملف ZIP غير صالح أو تالف"
        case .invalidIPA:        return "ملف IPA غير صالح أو تالف"
        case .missingFilesInZip: return "يجب توفير: .p12، .mobileprovision، وكلمة السر"
        case .noSigningAssets:   return "التطبيق لا يحتوي على مجلد signing-assets"
        }
    }
}
