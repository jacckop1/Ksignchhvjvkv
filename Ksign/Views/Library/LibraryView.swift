//
//  ContentView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import CoreData
import NimbleViews

// MARK: - Sort Options
enum LibrarySortOption: String, CaseIterable {
    case name      = "الاسم"
    case size      = "الحجم"
    case date      = "تاريخ الإضافة"
}

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _selectedAppDylibsPresenting: AnyApp?
	@State private var _isBulkSigningPresenting = false
    @State private var _isBulkInstallingPresenting = false
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _isAppStoreImportPresenting = false
	@State private var _appStoreImportSnapshot: AppStoreImportProgressSnapshot?
	@State private var _alertDownloadString: String = ""
	@State private var _searchText = ""
	@State private var _selectedTab: Int = 0

    // ← إضافة جديدة: حالة الفرز
    @State private var _sortOption: LibrarySortOption = .date
    @State private var _sortAscending: Bool = false
	
	// MARK: Edit Mode
    @State private var _isEditMode: EditMode = .inactive
	@State private var _selectedApps: Set<String> = []
	
	@Namespace private var _namespace
	
	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	// MARK: Filtering + Sorting
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
			(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}

    // ← فرز التطبيقات المحمّلة
    private var _filteredImportedApps: [Imported] {
        let filtered = filteredAndSortedApps(from: _importedApps)
        return _sort(filtered)
    }

    // ← فرز التطبيقات الموقّعة
    private var _filteredSignedApps: [Signed] {
        let filtered = filteredAndSortedApps(from: _signedApps)
        return _sort(filtered)
    }

    private func _sort<T: AppInfoPresentable>(_ apps: [T]) -> [T] {
        apps.sorted { a, b in
            let result: Bool
            switch _sortOption {
            case .name:
                result = (a.name ?? "") < (b.name ?? "")
            case .date:
                result = (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case .size:
                let sizeA = _fileSize(for: a)
                let sizeB = _fileSize(for: b)
                result = sizeA < sizeB
            }
            return _sortAscending ? result : !result
        }
    }

    private func _fileSize(for app: AppInfoPresentable) -> Int64 {
        guard let source = (app as? Signed)?.source ?? (app as? Imported)?.source else { return 0 }
        return (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
    }

	// MARK: Body
    var body: some View {
		NBNavigationView(.localized("Library")) {
			VStack(spacing: 0) {
				Picker("", selection: $_selectedTab) {
					Text(.localized("Downloaded Apps")).tag(0)
					Text(.localized("Signed Apps")).tag(1)
				}
				.pickerStyle(SegmentedPickerStyle())
				.padding(.horizontal)
				.padding(.vertical, 8)

				NBListAdaptable {
					if _selectedTab == 0 {
						if let snapshot = _appStoreImportSnapshot {
							NBSection("جاري السحب من App Store", secondary: "1") {
								AppStoreImportProgressRow(snapshot: snapshot)
							}
						}

						NBSection(
							.localized("Downloaded Apps"),
							secondary: _filteredImportedApps.count.description
						) {
							ForEach(_filteredImportedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedInstallAppPresenting: $_selectedInstallAppPresenting,
									selectedAppDylibsPresenting: $_selectedAppDylibsPresenting,
									selectedApps: $_selectedApps
								)
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
							}
						}
					} else {
						NBSection(
							.localized("Signed Apps"),
							secondary: _filteredSignedApps.count.description
						) {
							ForEach(_filteredSignedApps, id: \.uuid) { app in
								LibraryCellView(
									app: app,
									selectedInfoAppPresenting: $_selectedInfoAppPresenting,
									selectedSigningAppPresenting: $_selectedSigningAppPresenting,
									selectedInstallAppPresenting: $_selectedInstallAppPresenting,
									selectedAppDylibsPresenting: $_selectedAppDylibsPresenting,
									selectedApps: $_selectedApps
								)
								.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
							}
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
            .overlay {
                if _filteredSignedApps.isEmpty, _filteredImportedApps.isEmpty, _appStoreImportSnapshot == nil {
                    if #available(iOS 17, *) {
                        ContentUnavailableView {
                            Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
                        } description: {
                            Text(.localized("Get started by importing your first IPA file."))
                        } actions: {
                            Menu {
                                _importActions()
                            } label: {
                                Text("Import").bg()
                            }
                        }
                    }
                }
            }
			.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                if _isEditMode.isEditing {
					ToolbarItemGroup(placement: .topBarTrailing) {
                        if _selectedTab == 0 {
                            Button {
                                _isBulkSigningPresenting = true
                            } label: {
                                NBButton(.localized("Sign"), systemImage: "signature", style: .icon)
                            }
                            .disabled(_selectedApps.isEmpty)
                        } else {
                            Button {
                                _isBulkInstallingPresenting = true
                            } label: {
                                NBButton(.localized("Install"), systemImage: "square.and.arrow.down")
                            }
                            .disabled(_selectedApps.isEmpty)
                        }
						Button {
							_bulkDeleteSelectedApps()
						} label: {
							NBButton(.localized("Delete"), systemImage: "trash", style: .icon)
						}
						.disabled(_selectedApps.isEmpty)
					}
				} else {
                    // ← زر الفرز
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            // اتجاه الفرز
                            Section {
                                Button {
                                    withAnimation { _sortAscending = true }
                                } label: {
                                    Label("تصاعدي", systemImage: _sortAscending ? "checkmark" : "arrow.up")
                                }
                                Button {
                                    withAnimation { _sortAscending = false }
                                } label: {
                                    Label("تنازلي", systemImage: !_sortAscending ? "checkmark" : "arrow.down")
                                }
                            }
                            Divider()
                            // نوع الفرز
                            Section("فرز حسب") {
                                ForEach(LibrarySortOption.allCases, id: \.self) { option in
                                    Button {
                                        withAnimation { _sortOption = option }
                                    } label: {
                                        Label(
                                            option.rawValue,
                                            systemImage: _sortOption == option ? "checkmark" : ""
                                        )
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
					NBToolbarMenu(
						"إضافة تطبيق",
						style: .text,
						placement: .topBarTrailing
					) {
                        _importActions()
                    }
				}
			}
            .environment(\.editMode, $_isEditMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base, signAndInstall: app.signAndInstall)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.fullScreenCover(item: $_selectedAppDylibsPresenting) { app in
                DylibsView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.fullScreenCover(isPresented: $_isBulkSigningPresenting) {
				BulkSigningView(apps: _selectedApps.compactMap { id in
					(_importedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
					?? (_signedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
				})
				.compatNavigationTransition(id: _selectedApps.joined(separator: ","), ns: _namespace)
				.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ksign.bulkSigningFinished"))) { _ in
					_selectedTab = 1
				}
			}
            .sheet(isPresented: $_isBulkInstallingPresenting) {
                BulkInstallPreviewView(apps: _selectedApps.compactMap { id in
                    (_importedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
                    ?? (_signedApps.first(where: { $0.uuid == id }) as AppInfoPresentable?)
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						for ipas in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: ipas, id: id)
							downloadManager.handlePachageFile(url: ipas, dl: dl) { err in
								if err != nil {
									UIAlertController.showAlertWithOk(
										title: "Error",
										message: .localized("Whoops!, something went wrong when extracting the file. \nMaybe try switching the extraction library in the settings?")
									)
								}
							}
						}
					}
				)
			}
			.fullScreenCover(isPresented: $_isAppStoreImportPresenting) {
				AppStoreImportView()
			}
			.onReceive(NotificationCenter.default.publisher(for: .ksignAppStoreImportProgress)) { notification in
				if let snapshot = notification.object as? AppStoreImportProgressSnapshot {
					_appStoreImportSnapshot = snapshot
					_selectedTab = 0
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: .ksignAppStoreImportClear)) { _ in
				_appStoreImportSnapshot = nil
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("feather.installApp"))) { _ in
                if let app = _signedApps.first {
                    _selectedInstallAppPresenting = AnyApp(base: app)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ksign.openSigningForLatestApp"))) { notification in
				let fileName = (notification.userInfo?["fileName"] as? String)?
					.replacingOccurrences(of: ".ipa", with: "")
					.replacingOccurrences(of: ".tipa", with: "")
				_openSigningWithRetry(fileName: fileName, signAndInstall: false)
			}
			.onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ksign.signAndInstallLatest"))) { notification in
				let fileName = (notification.userInfo?["fileName"] as? String)?
					.replacingOccurrences(of: ".ipa", with: "")
					.replacingOccurrences(of: ".tipa", with: "")
				_openSigningWithRetry(fileName: fileName, signAndInstall: true)
			}
        }
        .onChange(of: _isEditMode) { state in
            if !state.isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now()) {
                    withAnimation {
                        _selectedApps.removeAll()
                    }
                }
            }
        }
    }
}

extension LibraryView {
    @ViewBuilder
    private func _importActions() -> some View {
        Button(.localized("Import from Files"), systemImage: "folder") {
            _isImportingPresenting = true
        }
        Button(.localized("Import from URL"), systemImage: "globe") {
            _isDownloadingPresenting = true
        }
        Button("سحب من App Store", systemImage: "apple.logo") {
            _selectedTab = 0
            _isAppStoreImportPresenting = true
        }
    }

    private func _openSigningWithRetry(fileName: String?, signAndInstall: Bool, attempt: Int = 0) {
        func findApp() -> Imported? {
            if let name = fileName, !name.isEmpty,
               let match = _importedApps.first(where: {
                   ($0.name ?? "").localizedCaseInsensitiveContains(name) ||
                   name.localizedCaseInsensitiveContains($0.name ?? "")
               }) {
                return match
            }
            return _importedApps.first
        }

        if let app = findApp() {
            _selectedSigningAppPresenting = AnyApp(base: app, signAndInstall: signAndInstall)
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                _openSigningWithRetry(fileName: fileName, signAndInstall: signAndInstall, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - App Store inline progress
private struct AppStoreImportProgressRow: View {
    let snapshot: AppStoreImportProgressSnapshot

    private var statusText: String {
        if let error = snapshot.errorMessage, !error.isEmpty { return error }
        if snapshot.retryScheduled {
            return "انقطع الاتصال — إعادة المحاولة تلقائياً (\(snapshot.retryAttempt)/3)…"
        }
        switch snapshot.phase {
        case .connecting:
            return "جاري الاتصال بـ App Store…"
        case .downloading:
            if snapshot.downloadedBytes > 0, snapshot.totalBytes > 0 {
                return "\(snapshot.downloadedBytes.formattedByteCount) من \(snapshot.totalBytes.formattedByteCount)"
            }
            return "جاري التنزيل…"
        case .processing:
            return "جاري إضافة التطبيق إلى التطبيقات غير الموقعة…"
        case .failed:
            return snapshot.errorMessage ?? "فشل التنزيل."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: snapshot.phase == .failed ? "exclamationmark.triangle.fill" : "apple.logo")
                    .font(.title3.weight(.semibold))
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.appName)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    if snapshot.totalBytes > 0 {
                        Text("الحجم: \(snapshot.totalBytes.formattedByteCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("جاري تحديد الحجم…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Text("\(snapshot.percentage)%")
                    .font(.subheadline.bold().monospacedDigit())
            }

            ProgressView(value: snapshot.progress, total: 1)
                .progressViewStyle(.linear)

            Text(statusText)
                .font(.caption.monospacedDigit())
                .foregroundColor(snapshot.phase == .failed ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if snapshot.phase == .failed {
                HStack(spacing: 10) {
                    Button {
                        AppStorePullManager.shared.retry()
                    } label: {
                        Label("إعادة المحاولة", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        AppStorePullManager.shared.cancel()
                    } label: {
                        Label("إلغاء", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Extension: View (Edit Mode Functions)
extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let appsToDelete = _selectedApps
		withAnimation(.easeInOut(duration: 0.5)) {
			for appUUID in appsToDelete {
				if let signedApp = _signedApps.first(where: { $0.uuid == appUUID }) {
					Storage.shared.deleteApp(for: signedApp)
				} else if let importedApp = _importedApps.first(where: { $0.uuid == appUUID }) {
					Storage.shared.deleteApp(for: importedApp)
				}
			}
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
			_selectedApps.removeAll()
		}
	}
}
