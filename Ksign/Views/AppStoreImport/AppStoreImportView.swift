import SwiftUI

struct AppStoreImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var app: AppStoreSoftware?

    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var savedAccount: AppStoreAccount?

    @State private var isLookingUp = false
    @State private var isPreparingDownload = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://apps.apple.com/.../id123456789", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        lookupApp()
                    } label: {
                        HStack {
                            Label("جلب التطبيق", systemImage: "magnifyingglass")
                            Spacer()
                            if isLookingUp { ProgressView() }
                        }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUp || isPreparingDownload)
                } header: {
                    Text("رابط App Store")
                } footer: {
                    Text("الصق رابط التطبيق الأصلي من App Store. المتجر يتعرف على App ID والبلد تلقائياً.")
                }

                if let app {
                    Section("التطبيق") {
                        HStack(spacing: 14) {
                            AsyncImage(url: URL(string: app.artworkUrl)) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Image(systemName: "app.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .padding(12)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            VStack(alignment: .leading, spacing: 5) {
                                Text(app.name)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(app.artistName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("الإصدار \(app.version) • \(formattedSize(app.fileSizeBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(app.bundleID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if let savedAccount {
                        HStack {
                            Label(savedAccount.email, systemImage: "person.crop.circle.badge.checkmark")
                            Spacer()
                            Text("متصل")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Button("تسجيل خروج الحساب", role: .destructive) {
                            AppStoreImportService.clearAccount()
                            self.savedAccount = nil
                            email = ""
                            password = ""
                            verificationCode = ""
                        }
                    } else {
                        TextField("Apple ID", text: $email)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)

                        SecureField("كلمة المرور", text: $password)

                        TextField("رمز التحقق 2FA (إذا طُلب)", text: $verificationCode)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("حساب Apple")
                } footer: {
                    Text("بيانات الحساب تحفظ محلياً داخل Keychain على الجهاز. يفضل استخدام حساب ثانوي مخصص للسحب.")
                }

                if let message {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if let app {
                    Section {
                        Button {
                            startAppStoreDownload(app)
                        } label: {
                            HStack {
                                Label("سحب من App Store", systemImage: "arrow.down.app.fill")
                                Spacer()
                                if isPreparingDownload { ProgressView() }
                            }
                        }
                        .disabled(isPreparingDownload || isLookingUp)
                    } footer: {
                        Text("هذه الخطوة تسحب حزمة App Store الأصلية من خوادم Apple. إذا كان التطبيق مجانياً وغير مملوك للحساب، يحاول المتجر إضافته إلى مشتريات الحساب أولاً. التطبيقات المدفوعة يجب أن تكون مملوكة مسبقاً. الحزمة تبقى محمية بـ FairPlay؛ هذه الميزة لا تفك DRM.")
                    }
                }
            }
            .navigationTitle("استيراد من App Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .onAppear {
                savedAccount = AppStoreImportService.loadAccount()
            }
        }
    }

    private func lookupApp() {
        isLookingUp = true
        errorMessage = nil
        message = nil
        app = nil

        Task {
            do {
                let software = try await AppStoreImportService.lookup(link)
                await MainActor.run {
                    app = software
                    isLookingUp = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = readableError(error)
                    isLookingUp = false
                }
            }
        }
    }

    private func startAppStoreDownload(_ software: AppStoreSoftware) {
        isPreparingDownload = true
        errorMessage = nil
        message = nil

        Task {
            do {
                var account: AppStoreAccount
                if let existing = AppStoreImportService.loadAccount() {
                    account = existing
                } else {
                    account = try await AppStoreImportService.authenticate(
                        email: email,
                        password: password,
                        code: verificationCode
                    )
                }

                let prepared = try await AppStoreImportService.prepareDownload(app: software, account: &account)
                try AppStoreImportService.saveAccount(account)

                await MainActor.run {
                    savedAccount = account
                    let expectedBytes = software.fileSizeBytes.flatMap { Int64($0) }
                    AppStorePullManager.shared.start(
                        url: prepared.url,
                        payload: prepared.payload,
                        appName: software.name,
                        expectedBytes: expectedBytes
                    )
                    isPreparingDownload = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    if let appStoreError = error as? AppStoreImportError, appStoreError == .sessionExpired {
                        AppStoreImportService.clearAccount()
                        savedAccount = nil
                        verificationCode = ""
                    }
                    errorMessage = readableError(error)
                    isPreparingDownload = false
                }
            }
        }
    }

    private func formattedSize(_ value: String?) -> String {
        guard let value, let bytes = Int64(value), bytes > 0 else { return "حجم غير معروف" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func readableError(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("verification") ||
            text.localizedCaseInsensitiveContains("code required") {
            return "الحساب يطلب تحقق بخطوتين. أدخل رمز 2FA ثم اضغط سحب مرة أخرى.\n\n\(text)"
        }
        return text
    }
}
