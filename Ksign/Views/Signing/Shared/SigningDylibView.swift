//
//  SigningDylibView.swift
//  Ksign
//

import SwiftUI
import NimbleViews
import ZsignSwift
import ZIPFoundation

// MARK: - View
struct SigningDylibView: View {
    @State private var _dylibs: [String] = []
    @State private var _hiddenDylibCount: Int = 0
    @State private var _isLoading = true
    @State private var _tmpDir: URL? = nil   // نحتفظ به حتى dismiss

    var app: AppInfoPresentable
    @Binding var options: Options?

    var body: some View {
        NBList(.localized("Dylibs"), type: .list) {
            if _isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(_dylibs, id: \.self) { dylib in
                        SigningToggleCellView(
                            title: dylib,
                            options: $options,
                            arrayKeyPath: \.disInjectionFiles
                        )
                    }
                }
                .disabled(options == nil)

                NBSection(.localized("Hidden")) {
                    Text(verbatim: .localized("%lld required system dylibs not shown",
                                              arguments: _hiddenDylibCount))
                        .font(.footnote)
                        .foregroundColor(.disabled())
                }
            }
        }
        .onAppear { _loadDylibs() }
        .onDisappear { _cleanupTmp() }
    }

    private func _cleanupTmp() {
        if let d = _tmpDir { try? FileManager.default.removeItem(at: d); _tmpDir = nil }
    }
}

// MARK: - Logic
extension SigningDylibView {
    private func _loadDylibs() {
        _isLoading = true

        Task.detached(priority: .userInitiated) {
            do {
                let (appDir, tmpDir) = try Storage.shared.resolveAppDir(for: app)

                let bundle   = Bundle(url: appDir)
                let execPath = appDir.appendingPathComponent(bundle?.exec ?? "").path

                let allDylibs = Zsign.listDylibs(appExecutable: execPath).map { $0 as String }
                let injected  = allDylibs.filter {
                    $0.hasPrefix("@rpath") || $0.hasPrefix("@executable_path")
                }
                let hidden = allDylibs.count - injected.count

                await MainActor.run {
                    _tmpDir           = tmpDir
                    _dylibs           = injected
                    _hiddenDylibCount = hidden
                    _isLoading        = false
                }
            } catch {
                await MainActor.run {
                    _isLoading = false
                }
            }
        }
    }
}
