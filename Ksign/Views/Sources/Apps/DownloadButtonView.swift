import SwiftUI
import Combine
import AltSourceKit
import NimbleViews
import UIKit

struct DownloadButtonView: View {
    let app: ASRepository.App
    var compact: Bool = false

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var downloadProgress: Double = 0
    @State private var cancellable: AnyCancellable?

    @State private var isSigning = false
    @State private var signingStatus = "جاري التوقيع..."
    @State private var signingError: String?
    @State private var showError = false

    private var downloadID: String {
        "FeatherManualDownload_\(app.currentUniqueId)"
    }

    var body: some View {
        ZStack {
            if let currentDownload = downloadManager.getDownload(by: downloadID)
                ?? downloadManager.getDownload(by: app.currentUniqueId) {
                Button {
                    if downloadProgress <= 0.75 {
                        downloadManager.cancelDownload(currentDownload)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .trim(from: 0, to: downloadProgress)
                            .stroke(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 31, height: 31)

                        Image(systemName: downloadProgress >= 0.75 ? "archivebox" : "square.fill")
                            .foregroundStyle(.tint)
                            .font(.footnote.bold())
                    }
                }
                .buttonStyle(.plain)
                .compatTransition()
            } else if isSigning {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.75)
                    Text(signingStatus)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(uiColor: .quaternarySystemFill))
                .clipShape(Capsule())
            } else {
                HStack(spacing: compact ? 8 : 6) {
                    Menu {
                        Button("تحميل الملف فقط", systemImage: "arrow.down.circle") {
                            startDownload(intent: .downloadOnly)
                        }
                        Button("تحميل وتوقيع", systemImage: "signature") {
                            startDownload(intent: .downloadAndSign)
                        }
                        Button("تحميل وتثبيت مباشرة", systemImage: "square.and.arrow.down") {
                            startDownload(intent: .downloadAndInstall)
                        }
                    } label: {
                        Text(.localized("Get"))
                            .lineLimit(1)
                            .font(.headline.bold())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, compact ? 12 : 18)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .quaternarySystemFill))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        startCloudInstall()
                    } label: {
                        Text("تثبيت")
                            .lineLimit(1)
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 10 : 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .compatTransition()
            }
        }
        .alert("فشل التثبيت", isPresented: $showError) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(signingError ?? "خطأ غير معروف")
        }
        .onAppear(perform: setupObserver)
        .onDisappear { cancellable?.cancel() }
        .onChange(of: downloadManager.downloads.description) { _ in
            setupObserver()
        }
    }

    private func startDownload(intent: DownloadIntent) {
        guard let url = app.currentDownloadUrl else { return }
        _ = downloadManager.startDownload(from: url, id: downloadID, intent: intent)
    }

    private func startCloudInstall() {
        guard let ipaURL = app.currentDownloadUrl?.absoluteString else { return }

        isSigning = true
        signingStatus = "جاري الإرسال..."
        CocoCloudService.requestNotificationPermission()

        CocoCloudService.shared.signWithUserCert(
            ipaURL: ipaURL,
            appDisplayName: app.name ?? "التطبيق",
            onProgress: { status in
                DispatchQueue.main.async {
                    signingStatus = status
                }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isSigning = false
                    switch result {
                    case .success(let itmsURL):
                        guard let url = URL(string: itmsURL) else {
                            signingError = "رابط التثبيت غير صالح."
                            showError = true
                            return
                        }
                        UIApplication.shared.open(url)
                    case .failure(let error):
                        signingError = error.localizedDescription
                        showError = true
                    }
                }
            }
        )
    }

    private func setupObserver() {
        cancellable?.cancel()
        guard let download = downloadManager.getDownload(by: downloadID)
            ?? downloadManager.getDownload(by: app.currentUniqueId) else {
            downloadProgress = 0
            return
        }

        downloadProgress = download.overallProgress
        cancellable = Publishers.CombineLatest(download.$progress, download.$unpackageProgress)
            .receive(on: DispatchQueue.main)
            .sink { _, _ in
                downloadProgress = download.overallProgress
            }
    }
}
