//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews
import UserNotifications

// MARK: - ShareSheet Helper
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@Namespace var _namespace

	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isLogsPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State private var _baseIdentifier: String? = nil
	@State var appIcon: UIImage?
	@State private var _injectAdBlock: Bool = false
	@State private var _injectFix: Bool = false

    // ← إضافة جديدة: Share بعد التوقيع
    @State private var _signedAppURL: URL? = nil
    @State private var _isSharePresenting = false
    // ← تثبيت مباشر بعد التوقيع (signAndInstall=true)
    @State private var _appToInstall: AnyApp? = nil
	
	@State var signAndInstall: Bool = false
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	private func _getCertAppID() -> String? {
		guard
			let cert = _selectedCert(),
			let decoded = Storage.shared.getProvisionFileDecoded(for: cert),
			let entitlements = decoded.Entitlements,
			let appID = entitlements["application-identifier"]?.value as? String
		else {
			return nil
		}
		return appID.split(separator: ".").dropFirst().joined(separator: ".")
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable, signAndInstall: Bool = false) {
		self.app = app
		// @State يحتاج التهيئة عبر الـ underscore wrapper في init
		_signAndInstall = State(initialValue: signAndInstall)
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView(app.name ?? .localized("Unknown"), displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_cert()
				_injectAddons()
				_customizationProperties(for: app)
			}
			.disabled(_isSigning)
			.safeAreaInset(edge: .bottom) {
				if _isSigning {
                    // لا نعرض زر Show Logs أثناء التوقيع حتى لا يربك المستخدم
                    // أو يفتح شاشة إضافية بالخطأ. اللوجات تبقى متاحة من الإعدادات.
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("جاري التوقيع...")
                            .font(.headline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    .padding(.bottom, 4)
				} else {
					Button() {
						_start()
					} label: {
						NBSheetButton(title: .localized("Start Signing"))
					}
				}
			}
			.toolbar {
				NBToolbarButton(role: .dismiss)
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
					_baseIdentifier = nil
					_injectAdBlock = false
					_injectFix = false
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.fullScreenCover(isPresented: $_isLogsPresenting) {
				LogsView(manager: LogsManager.shared)
					.compatNavigationTransition(id: "showLogs", ns: _namespace)
			}
            // ← إضافة جديدة: sheet الشير
            .sheet(isPresented: $_isSharePresenting, onDismiss: { dismiss() }) {
                if let url = _signedAppURL {
                    ShareSheet(items: [url])
                }
            }
            // ← تثبيت مباشر بعد التوقيع
            .sheet(item: $_appToInstall) { app in
                InstallPreviewView(app: app.base)
                    .presentationDetents([.height(200)])
                    .presentationDragIndicator(.visible)
                    .onDisappear { dismiss() }
            }
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
			if _optionsManager.options.prefix != nil || _optionsManager.options.suffix != nil {
				var name = app.name ?? ""
				if let dictName = _temporaryOptions.displayNames[name] { name = dictName }
				if let prefix = _optionsManager.options.prefix { name = prefix + name }
				if let suffix = _optionsManager.options.suffix { name = name + suffix }
				_temporaryOptions.appName = name
			}
			// ✅ إذا طُلب التوقيع والتثبيت تلقائياً — ابدأ فوراً بعد ثانية
			if signAndInstall {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
					_start()
				}
			}
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon")) { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files")) { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos")) { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle(size: 55)
				} else {
					FRAppIconView(app: app, size: 55)
				}
			}
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_identifierCell(for: app)
		}
	}
	
	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(cert: cert)
				}
			}
		}
	}

	@ViewBuilder
	private func _injectAddons() -> some View {
		NBSection("حقن الإضافات") {
			Toggle(isOn: $_injectAdBlock) {
				Label("حقن مانع الإعلانات", systemImage: "shield.slash")
			}
			Toggle(isOn: $_injectFix) {
				Label("حقن إصلاح التطبيق", systemImage: "wrench.and.screwdriver")
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink("تعديل الديلبات") {
					SigningDylibView(app: app, options: $_temporaryOptions.optional())
				}
				NavigationLink(String.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(app: app, options: $_temporaryOptions.optional())
				}
				#if NIGHTLY || DEBUG
				NavigationLink(String.localized("Entitlements")) {
					SigningEntitlementsView(bindingValue: $_temporaryOptions.appEntitlementsFile)
				}
				#endif
				NavigationLink("اضافة ديلب") {
					SigningTweaksView(options: $_temporaryOptions)
				}
			}
			NavigationLink(String.localized("Properties")) {
				Form {
					SigningOptionsView(
						options: $_temporaryOptions,
						temporaryOptions: _optionsManager.options
					)
				}
				.navigationTitle(.localized("Properties"))
			}
		}
	}

	@ViewBuilder
	private func _identifierCell(for app: AppInfoPresentable) -> some View {
		HStack(spacing: 0) {
			NavigationLink {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					certAppId: _getCertAppID(),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			} label: {
				LabeledContent(.localized("Identifier")) {
					Text(_temporaryOptions.appIdentifier ?? app.identifier ?? .localized("Unknown"))
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			Divider()
				.frame(height: 20)
				.padding(.horizontal, 10)
			Menu {
				ForEach(1...5, id: \.self) { number in
					Button {
						if _baseIdentifier == nil { _baseIdentifier = app.identifier }
						let base = _baseIdentifier ?? app.identifier ?? ""
						_temporaryOptions.appIdentifier = base + "\(number)"
						UIImpactFeedbackGenerator(style: .light).impactOccurred()
					} label: {
						Label(
							"نسخة مكررة \(number == 1 ? "أولى" : number == 2 ? "ثانية" : number == 3 ? "ثالثة" : number == 4 ? "رابعة" : "خامسة")",
							systemImage: "\(number).circle"
						)
					}
				}
				Divider()
				Button {
					let current = _temporaryOptions.appIdentifier ?? app.identifier ?? ""
					let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
					let suffix = String((0..<2).compactMap { _ in chars.randomElement() })
					_temporaryOptions.appIdentifier = current + suffix
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				} label: {
					Label("تكرار لا نهائي", systemImage: "infinity")
				}
			} label: {
				Text("تكرار التطبيق")
					.font(.system(size: 12, weight: .medium))
					.foregroundColor(.accentColor)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
			}
			.buttonStyle(.borderless)
		}
	}

	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard _selectedCert() != nil || _temporaryOptions.doAdhocSigning || _temporaryOptions.onlyModify else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()

        // اللوجات لا تُلتقط ولا تُفتح افتراضياً. يتم تشغيلها فقط عندما
        // يفعّل المستخدم خيارها يدوياً من الإعدادات.
        if _optionsManager.options.signingLogs {
            LogsManager.shared.startCapture()
            _isLogsPresenting = true
        } else {
            _isLogsPresenting = false
        }

		_isSigning = true

        do {
            let extraURLs = try _bundledDylibURLs()

            if _injectAdBlock || _injectFix {
                _temporaryOptions.injectPath = .executable_path
                _temporaryOptions.injectFolder = .frameworks
            }

            for url in extraURLs where !_temporaryOptions.injectionFiles.contains(url) {
                _temporaryOptions.injectionFiles.append(url)
            }

            _beginSigning()
        } catch {
            _isSigning = false
            if _optionsManager.options.signingLogs {
                LogsManager.shared.stopCapture()
            }
            UIAlertController.showAlertWithOk(
                title: "حقن الإضافات",
                message: error.localizedDescription
            )
        }
	}

    /// يحضّر نسخة محلية بامتداد dylib من الملفات المدمجة داخل التطبيق.
    /// الملفات مخزنة بامتداد .kira حتى يتعامل معها Xcode كموارد عادية،
    /// ثم تُنسخ محلياً لحظة التوقيع بدون أي اتصال بالإنترنت.
    private func _bundledDylibURLs() throws -> [URL] {
        var names: [String] = []

        if _injectAdBlock {
            names.append(contentsOf: ["Gadblock", "iKiraPlus", "NoAds"])
        }

        if _injectFix {
            names.append(contentsOf: ["Sideloadbypass1", "Sideloadbypass2", "sideloadFixerLol"])
        }

        guard !names.isEmpty else { return [] }

        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("KiraBundledDylibs", isDirectory: true)
        try fileManager.createDirectoryIfNeeded(at: outputDirectory)

        return try names.map { name in
            guard let bundledURL = _bundledDylibResource(named: name) else {
                throw NSError(
                    domain: "KiraStore.BundledDylibs",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "ملف الإضافة \(name).dylib غير موجود داخل التطبيق. أعد بناء المشروع وتأكد من تضمين مجلد BundledDylibs ضمن Resources."]
                )
            }

            let destinationURL = outputDirectory.appendingPathComponent("\(name).dylib")
            let encodedData = try Data(contentsOf: bundledURL)

            guard
                let encodedText = String(data: encodedData, encoding: .utf8),
                let dylibData = Data(
                    base64Encoded: encodedText,
                    options: [.ignoreUnknownCharacters]
                ),
                !dylibData.isEmpty
            else {
                throw NSError(
                    domain: "KiraStore.BundledDylibs",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "تعذر فك ملف الإضافة \(name).dylib داخل التطبيق."]
                )
            }

            try? fileManager.removeItem(at: destinationURL)
            try dylibData.write(to: destinationURL, options: .atomic)

            // تحافظ على قابلية تحميل الملف بعد إنشائه داخل التطبيق المراد توقيعه.
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: destinationURL.path
            )

            return destinationURL
        }
    }

    private func _bundledDylibResource(named name: String) -> URL? {
        let bundle = Bundle.main

        // يدعم حالتي نسخ الموارد: مسطحة أو مع المحافظة على المجلد.
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "kira"),
            bundle.url(forResource: name, withExtension: "kira", subdirectory: "BundledDylibs"),
            bundle.url(forResource: name, withExtension: "kira", subdirectory: "Resources/BundledDylibs")
        ]

        if let match = candidates.compactMap({ $0 }).first {
            return match
        }

        return bundle.urls(forResourcesWithExtension: "kira", subdirectory: nil)?
            .first { $0.deletingPathExtension().lastPathComponent == name }
    }

	private func _beginSigning() {
		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { [self] error in
            _isSigning = false
            if _optionsManager.options.signingLogs {
                LogsManager.shared.stopCapture()
            }
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				UIAlertController.showAlert(
					title: .localized("Signing"),
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				if _temporaryOptions.removeApp && !app.isSigned {
					Storage.shared.deleteApp(for: app)
				}

                let appName = _temporaryOptions.appName ?? app.name ?? "التطبيق"
                _sendSigningNotification(for: appName)

                if signAndInstall {
                    // نبحث عن التطبيق الموقّع للتو في Storage ونفتح التثبيت مباشرة
                    // نعطي CoreData 0.4ث لحفظ السجل ثم نفتح شاشة التثبيت
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let signed = Storage.shared.getLatestSignedApp() {
                            _appToInstall = AnyApp(base: signed)
                        } else {
                            // fallback: أرسل notification للمكتبة
                            NotificationCenter.default.post(
                                name: NSNotification.Name("feather.installApp"),
                                object: nil
                            )
                            dismiss()
                        }
                    }
                } else {
                    dismiss()
                }
			}
		}
	}

    // ← إضافة جديدة: دالة الإشعار المحلي
    private func _sendSigningNotification(for appName: String) {
        guard OptionsManager.shared.options.notifications else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "✅ تم التوقيع بنجاح"
            content.body = "تم توقيع \(appName) بنجاح، يمكنك الآن تثبيته."
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "signing.completed.\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )

            UNUserNotificationCenter.current().add(request)
        }
    }
}
