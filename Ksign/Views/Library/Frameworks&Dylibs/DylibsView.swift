//
//  DylibsView.swift
//  Ksign
//
//  Created by Nagata Asami on 22/5/25.
//

import SwiftUI
import NimbleViews
import ZsignSwift
import ZIPFoundation

struct DylibsView: View {
    var app: AppInfoPresentable
    @Environment(\.dismiss) private var dismiss
    @AppStorage("Feather.useLastExportLocation") private var _useLastExportLocation: Bool = false

    @State private var dylibFiles: [URL] = []
    @State private var selectedDylibs: [URL] = []
    @State private var showDirectoryPicker = false
    @State private var hiddenDylibCount: Int = 0
    @State private var searchText: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String? = nil

    // مجلد مؤقت نفك فيه الـ IPA
    @State private var _tempDir: URL? = nil

    var body: some View {
        NBNavigationView(app.name ?? .localized("Frameworks & Dylibs"), displayMode: .inline) {
            Group {
                if isLoading {
                    ProgressView("جاري التحميل...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack {
                        List(
                            dylibFiles.filter {
                                searchText.isEmpty ? true : $0.lastPathComponent.localizedCaseInsensitiveContains(searchText)
                            },
                            id: \.absoluteString
                        ) { fileURL in
                            DylibRowView(
                                fileURL: fileURL,
                                isSelected: selectedDylibs.contains(fileURL),
                                toggleSelection: { toggleDylibSelection(fileURL) }
                            )
                        }
                        .listStyle(.plain)
                        if hiddenDylibCount > 0 {
                            Text(verbatim: .localized("%lld required system dylibs not shown", arguments: hiddenDylibCount))
                                .font(.footnote)
                                .foregroundColor(.disabled())
                        }
                    }
                    .overlay(alignment: .center) {
                        if dylibFiles.isEmpty {
                            if #available(iOS 17.0, *) {
                                ContentUnavailableView(
                                    .localized("No Frameworks"),
                                    systemImage: "doc.text.magnifyingglass",
                                    description: Text(.localized("No frameworks or dylibs found in this app"))
                                )
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(.localized("Cancel")) { _cleanup(); dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        FRAppIconView(app: app, size: 28)
                        Text(app.name ?? .localized("Frameworks & Dylibs"))
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(.localized("Copy")) { showDirectoryPicker = true }
                        .disabled(selectedDylibs.isEmpty)
                }
            }
            .onAppear { loadDylibFiles() }
            .onDisappear { _cleanup() }
            .sheet(isPresented: $showDirectoryPicker) {
                FileExporterRepresentableView(
                    urlsToExport: selectedDylibs,
                    asCopy: true,
                    useLastLocation: _useLastExportLocation,
                    onCompletion: { _ in selectedDylibs.removeAll() }
                )
            }
            .searchable(text: $searchText)
        }
    }

    // MARK: - تنظيف الملفات المؤقتة
    private func _cleanup() {
        if let tmp = _tempDir {
            try? FileManager.default.removeItem(at: tmp)
            _tempDir = nil
        }
    }

    // MARK: - تحميل الـ dylibs
    private func loadDylibFiles() {
        dylibFiles = []
        hiddenDylibCount = 0
        isLoading = true
        loadError = nil

        guard let ipaURL = Storage.shared.getAppDirectory(for: app) else {
            isLoading = false
            loadError = "لم يتم العثور على ملف التطبيق."
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ── فك ضغط الـ IPA في مجلد مؤقت ──────────────────────
                let tmpDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DylibsView_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

                let archive = try Archive(url: ipaURL, accessMode: .read)
                for entry in archive {
                    // نفك فقط ملفات .app (نتجاهل __MACOSX وغيرها)
                    guard !entry.path.hasPrefix("__MACOSX") else { continue }
                    let dest = tmpDir.appendingPathComponent(entry.path)
                    let parentDir = dest.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    _ = try? archive.extract(entry, to: dest)
                }

                // ── ابحث عن مجلد .app داخل Payload ────────────────────
                let payloadDir = tmpDir.appendingPathComponent("Payload")
                let payloadContents = (try? FileManager.default.contentsOfDirectory(
                    at: payloadDir,
                    includingPropertiesForKeys: nil
                )) ?? []
                guard let appDir = payloadContents.first(where: { $0.pathExtension == "app" }) else {
                    DispatchQueue.main.async {
                        isLoading = false
                        loadError = "لم يتم العثور على مجلد .app داخل الـ IPA."
                        try? FileManager.default.removeItem(at: tmpDir)
                    }
                    return
                }

                // ── استخرج الـ dylibs عبر Zsign ────────────────────────
                let bundle = Bundle(url: appDir)
                let execPath = appDir.appendingPathComponent(bundle?.exec ?? "").relativePath
                let allDylibs = Zsign.listDylibs(appExecutable: execPath).map { $0 as String }
                let visibleDylibs = allDylibs.filter {
                    $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path")
                }
                let hiddenCount = allDylibs.count - visibleDylibs.count

                // ── ابحث عن ملفات .framework و .dylib ─────────────────
                let searchPaths = [
                    appDir,
                    appDir.appendingPathComponent("Frameworks")
                ]
                var collectedFiles: [URL] = []
                for path in searchPaths {
                    guard FileManager.default.fileExists(atPath: path.path) else { continue }
                    let fileURLs = (try? FileManager.default.contentsOfDirectory(
                        at: path,
                        includingPropertiesForKeys: nil
                    )) ?? []
                    collectedFiles.append(contentsOf: fileURLs.filter {
                        let ext = $0.pathExtension.lowercased()
                        return ext == "framework" || ext == "dylib"
                    })
                }
                let sorted = collectedFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }

                DispatchQueue.main.async {
                    _tempDir = tmpDir
                    dylibFiles = sorted
                    hiddenDylibCount = hiddenCount
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    loadError = "خطأ أثناء قراءة الملف: \(error.localizedDescription)"
                }
            }
        }
    }

    private func toggleDylibSelection(_ fileURL: URL) {
        if let index = selectedDylibs.firstIndex(of: fileURL) {
            selectedDylibs.remove(at: index)
        } else {
            selectedDylibs.append(fileURL)
        }
    }
}
