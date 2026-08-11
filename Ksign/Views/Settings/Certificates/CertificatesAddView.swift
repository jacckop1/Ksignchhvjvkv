//
//  CertificatesAddView.swift
//  Feather
//
//  Created by samara on 15.04.2025.
//

import SwiftUI
import NimbleViews
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - View
struct CertificatesAddView: View {
	@Environment(\.dismiss) private var dismiss
	
	@State private var _p12URL: URL? = nil
	@State private var _provisionURL: URL? = nil
	@State private var _p12Password: String = ""
	@State private var _isPasswordVisible: Bool = false
	@State private var _certificateName: String = ""
	
	@State private var _p12Data: Data? = nil
	@State private var _provisionData: Data? = nil
	@State private var _isFromKsign: Bool = false
	
	@State private var _isImportingP12Presenting = false
	@State private var _isImportingMobileProvisionPresenting = false
	@State private var _isImportingZipPresenting = false
	@State private var _errorMessage: String = ""
	@State private var _isErrorPresenting = false
	@State private var _zipPasswordNeeded = false
	@State private var _zipManualPassword: String = ""
	
	var saveButtonDisabled: Bool {
		if _isFromKsign {
			return _p12Data == nil || _provisionData == nil
		} else {
			return _p12URL == nil || _provisionURL == nil
		}
	}
	
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("New Certificate"), displayMode: .inline) {
			Form {
				NBSection(.localized("Files")) {
					_importButton("استيراد ملف الشهادة الـ P12", file: _p12URL, hasData: _p12Data) {
						_isImportingP12Presenting = true
					}
					_importButton("استيراد ملف الشهادة الـ MobileProvision", file: _provisionURL, hasData: _provisionData) {
						_isImportingMobileProvisionPresenting = true
					}
				}
				NBSection(.localized("Password")) {
					HStack {
						Group {
							if _isPasswordVisible {
								TextField(.localized("Enter Password"), text: $_p12Password)
							} else {
								SecureField(.localized("Enter Password"), text: $_p12Password)
							}
						}
						.textContentType(.oneTimeCode)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						
						Button {
							_isPasswordVisible.toggle()
						} label: {
							Image(systemName: _isPasswordVisible ? "eye.slash" : "eye")
								.foregroundColor(.secondary)
						}
						.buttonStyle(.plain)
					}
				} footer: {
					Text(.localized("Enter the password associated with the private key. Leave it blank if theres no password required."))
				}
				
				// ── استيراد ZIP ──────────────────────────────
				Section {
					Button {
						_isImportingZipPresenting = true
					} label: {
						Label("استيراد ملف الشهادة ZIP", systemImage: "doc.zipper")
							.foregroundColor(.accentColor)
					}
				} footer: {
					Text("ملف مضغوط يحتوي على ملف P12 وملف MobileProvision وملف نصي بكلمة المرور. يتم استيراد الشهادة تلقائياً.")
				}
				// ─────────────────────────────────────────────
				
				Section {
					TextField(.localized("Nickname (Optional)"), text: $_certificateName)
				}
			}
			.toolbar {
				NBToolbarButton(role: .cancel)
				
				NBToolbarButton(
					.localized("Save"),
					style: .text,
					placement: .confirmationAction,
					isDisabled: saveButtonDisabled
				) {
					_saveCertificate()
				}
			}
			// استيراد P12
			.sheet(isPresented: $_isImportingP12Presenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [UTType.p12],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self._p12URL = selectedFileURL
						self._isFromKsign = false
					}
				)
			}
			// استيراد MobileProvision
			.sheet(isPresented: $_isImportingMobileProvisionPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [UTType.mobileProvision],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self._provisionURL = selectedFileURL
						self._isFromKsign = false
					}
				)
			}
			// استيراد ZIP
			.sheet(isPresented: $_isImportingZipPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [UTType.zip],
					onDocumentsPicked: { urls in
						guard let zipURL = urls.first else { return }
						_extractCertificateZip(from: zipURL)
					}
				)
			}
			// تحذير: ما لقى كلمة المرور — يطلب إدخالها يدوي
			.alert("كلمة المرور غير موجودة في الملف", isPresented: $_zipPasswordNeeded) {
				SecureField("أدخل كلمة المرور يدوياً", text: $_zipManualPassword)
					.textContentType(.oneTimeCode)
					.autocorrectionDisabled()
					.textInputAutocapitalization(.never)
				Button("تأكيد") {
					_p12Password = _zipManualPassword
					_zipManualPassword = ""
				}
				Button("إلغاء", role: .cancel) {
					_zipManualPassword = ""
				}
			} message: {
				Text("لم يتم العثور على ملف نصي يحتوي كلمة المرور داخل ZIP. يمكنك إدخالها يدوياً أو تركها فارغة إذا لم تكن هناك كلمة مرور.")
			}
			// خطأ عام
			.alert(isPresented: $_isErrorPresenting) {
				Alert(
					title: Text(.localized("Import Error")),
					message: Text(_errorMessage),
					dismissButton: .default(Text(.localized("OK")))
				)
			}
		}
	}
}

// MARK: - Extension: View (buttons)
extension CertificatesAddView {
	@ViewBuilder
	private func _importButton(
		_ title: String,
		file: URL?,
		hasData: Data? = nil,
		action: @escaping () -> Void
	) -> some View {
		Button(title) {
			action()
		}
		.foregroundColor((file == nil && hasData == nil) ? .accentColor : .disabled())
		.disabled(file != nil || hasData != nil)
		.animation(.easeInOut(duration: 0.3), value: file != nil || hasData != nil)
	}
}

// MARK: - Extension: View (save & zip)
extension CertificatesAddView {
	private func _saveCertificate() {
        guard
            let p12URL = _p12URL,
            let provisionURL = _provisionURL
        else {
            return
        }

        // ملاحظة: تم إزالة التحقق الحاجب عبر SecPKCS12Import لأنه يرفض ملفات P12
        // الحديثة (المُصدّرة بـ OpenSSL 3.x باستخدام AES-256) حتى لو كانت كلمة
        // المرور صحيحة، بسبب قِدم Security framework في iOS. التحقق الحقيقي
        // يحدث أثناء التوقيع عبر Zsign الذي يدعم هذه الصيغ.
        //
        // نستخدم الفحص فقط كتحذير غير حاجب: إن فشل، قد تكون كلمة المرور
        // خاطئة أو قد تكون الصيغة غير قابلة للفحص محلياً — لا نمنع الحفظ.
        let passwordSeemsValid = FR.checkPasswordForCertificate(
            for: p12URL,
            with: _p12Password,
            using: provisionURL
        )

        FR.handleCertificateFiles(
            p12URL: p12URL,
            provisionURL: provisionURL,
            p12Password: _p12Password,
            certificateName: _certificateName
        ) { error in
            if let error = error {
                _errorMessage = "فشل حفظ الشهادة: \(error.localizedDescription)"
                _isErrorPresenting = true
            } else if !passwordSeemsValid {
                _errorMessage = "تم حفظ الشهادة، لكن لم يتم التحقق من كلمة المرور بنجاح. قد تكون كلمة المرور غير صحيحة، أو أن نظام iOS لا يدعم فحص هذا النوع من ملفات P12 مباشرة. إذا فشل التوقيع لاحقاً بسبب كلمة المرور، تأكد من صحتها."
                _isErrorPresenting = true
                dismiss()
            } else {
                dismiss()
            }
        }
	}
	
	/// يفك ضغط ZIP ويستخرج P12 و MobileProvision وكلمة المرور من ملف txt
	private func _extractCertificateZip(from zipURL: URL) {
		guard let archive = Archive(url: zipURL, accessMode: .read) else {
			_errorMessage = "لم يتم التعرف على الملف كملف ZIP صالح."
			_isErrorPresenting = true
			return
		}
		
		let tempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("CertImport_\(UUID().uuidString)")
		
		try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
		
		var foundP12: URL? = nil
		var foundProvision: URL? = nil
		var passwordCandidates: [(name: String, value: String)] = []
		
		for entry in archive {
			let fullPath = entry.path
			let name = (fullPath as NSString).lastPathComponent.lowercased()
			
			// تجاهل ملفات الميتاداتا الخاصة بـ macOS (__MACOSX/._اسم)
			if fullPath.hasPrefix("__MACOSX") || name.hasPrefix("._") {
				continue
			}
			
			let destURL = tempDir.appendingPathComponent(name)
			
			// استخراج الملف
			do {
				_ = try archive.extract(entry, to: destURL)
			} catch {
				continue
			}
			
			if name.hasSuffix(".p12") {
				foundP12 = destURL
			} else if name.hasSuffix(".mobileprovision") {
				foundProvision = destURL
			} else if name == "readme.txt" || name == "pass.txt" || name == "password.txt" {
				// قراءة كلمة المرور من الملف النصي
				var content: String? = try? String(contentsOf: destURL, encoding: .utf8)
				if content == nil {
					// محاولة قراءة بترميزات أخرى في حال فشل UTF-8 (مثل UTF-16 مع BOM)
					if let data = try? Data(contentsOf: destURL) {
						content = String(data: data, encoding: .utf16)
							?? String(data: data, encoding: .isoLatin1)
					}
				}
				if let content = content {
					if let extracted = _extractPasswordToken(from: content) {
						passwordCandidates.append((name: name, value: extracted))
					}
				}
			}
		}
		
		// اختيار كلمة المرور الصحيحة من بين المرشحين (readme.txt / pass.txt / password.txt):
		// 1) نفضّل pass.txt أو password.txt إن وُجد.
		// 2) وإلا نأخذ من readme.txt.
		var foundPassword: String? = nil
		if let preferred = passwordCandidates.first(where: { $0.name == "password.txt" })
			?? passwordCandidates.first(where: { $0.name == "pass.txt" })
			?? passwordCandidates.first(where: { $0.name == "readme.txt" }) {
			foundPassword = preferred.value
		}
		
		guard let p12URL = foundP12, let provisionURL = foundProvision else {
			_errorMessage = "لم يتم العثور على ملف P12 أو MobileProvision داخل ZIP. تأكد أن الملف يحتوي على الملفين."
			_isErrorPresenting = true
			return
		}
		
		// حفظ الملفات
		_p12URL = p12URL
		_provisionURL = provisionURL
		_isFromKsign = false
		
		if let password = foundPassword {
			// وجدنا كلمة المرور تلقائياً — نضعها مباشرة بدون تغيير
			_p12Password = password
		} else {
			// ما لقينا ملف txt — نطلب من المستخدم يدوياً
			_zipPasswordNeeded = true
		}
	}
	
	/// تنظف النص من BOM والمحارف الخفية، وتحاول استخراج رمز كلمة المرور
	/// (مثل applejr.net أو AppleP12.com) من بين النص حتى لو كان هناك سطور
	/// أو كلمات إضافية حوله.
	private func _extractPasswordToken(from rawContent: String) -> String? {
		// 1) إزالة BOM ومحارف Unicode الخفية (zero-width, RTL/LTR marks, إلخ)
		var cleaned = rawContent.unicodeScalars.filter { scalar in
			!(scalar.value == 0xFEFF ||
			  scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D ||
			  scalar.value == 0x200E || scalar.value == 0x200F ||
			  (scalar.value >= 0x202A && scalar.value <= 0x202E))
		}.reduce(into: "") { $0.unicodeScalars.append($1) }
		
		cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
		if cleaned.isEmpty { return nil }
		
		let lines = cleaned.components(separatedBy: .newlines)
		
		// 2) البحث عن رموز معروفة شائعة الاستخدام كأسماء/كلمات مرور لمجموعات
		//    توقيع معينة (مثل WSF, dxsign, khoindvn, khoindvn.io.vn ...).
		//    يتم البحث عنها كـ "كلمة كاملة" بحيث لا تُطابق جزءاً من كلمة أخرى.
		let knownTokens = [
			"khoindvn.io.vn",
			"khoindvn",
			"dxsign",
			"applejr.net",
			"AppleP12.com",
			"WSF",
			"123",
		]
		for token in knownTokens {
			let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9])"
			if cleaned.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
				return token
			}
		}
		
		// 2.1) البحث عن الرقم "1" بمفرده (سطر مستقل أو محاط بفواصل/مسافات فقط)
		for line in lines {
			let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmedLine == "1" {
				return "1"
			}
		}
		
		// 4) البحث عن سطر يحتوي كلمة دلالية مثل "password" / "pass" / "pwd" /
		//    "باسورد" / "الرمز" / "كلمة المرور"، ثم استخراج ما بعدها مباشرة
		//    (بعد : أو = أو - أو فقط مسافة) كقيمة كلمة المرور، أياً كانت
		//    (حروف، أرقام، أو حتى رقم واحد مثل "1").
		let keywords = ["password", "pass", "pwd", "باسورد", "الرمز", "كلمة المرور", "كلمة السر"]
		for line in lines {
			let lower = line.lowercased()
			guard let keywordRange = keywords.first(where: { lower.contains($0) || line.contains($0) })
				.flatMap({ kw in line.range(of: kw, options: .caseInsensitive) }) else {
				continue
			}
			
			var rest = String(line[keywordRange.upperBound...])
			// إزالة أي فواصل شائعة في البداية: : = - مسافات
			rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :=-\t"))
			rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
			
			if !rest.isEmpty {
				return rest
			}
		}
		
		// 5) البحث عن رمز يشبه "كلمة.امتداد" مثل applejr.net أو AppleP12.com
		//    (أحرف/أرقام، نقطة، ثم 2-10 أحرف للامتداد، بدون مسافات)
		if let tokenRange = cleaned.range(
			of: #"[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z]{2,10}"#,
			options: .regularExpression
		) {
			let token = String(cleaned[tokenRange])
			return token.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		
		// 6) لا وجود لأنماط واضحة — إن كان هناك سطر واحد فقط غير فارغ، نأخذه كما هو
		let nonEmptyLines = lines
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		if nonEmptyLines.count == 1 {
			return nonEmptyLines[0]
		}
		
		return nil
	}
}
