//
//  LibraryAppIconView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews
import ZIPFoundation

// MARK: - View
struct LibraryCellView: View {
	@AppStorage("Feather.libraryCellAppearance") private var _libraryCellAppearance: Int = 0
    @Environment(\.editMode) private var editMode
	var certInfo: Date.ExpirationInfo? {
		Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
	}
	
	var app: AppInfoPresentable
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppDylibsPresenting: AnyApp?
	@Binding var selectedApps: Set<String>
	@State private var _showActionSheet = false
    @State private var _showCertInject = false

    private var _certName: String? {
        Storage.shared.getCertificate(from: app)?.nickname
    }

    // اسم الشهادة المستخرج من embedded.mobileprovision داخل IPA
    @State private var _importedCertName: String? = nil
	
	private var _isSelected: Bool {
		selectedApps.contains(app.uuid ?? "")
	}

	// MARK: Body
	var body: some View {
        let isEditing = editMode?.wrappedValue == .active
        HStack(spacing: 9) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			FRAppIconView(app: app, size: 57)
			
			VStack(alignment: .leading, spacing: 2) {
				NBTitleWithSubtitleView(
					title: app.name ?? .localized("Unknown"),
					subtitle: _desc,
					linelimit: 0
				)
                // ← للموقّعة: اسم الشهادة من CoreData | للمستوردة: مستخرج من IPA
                if let name = app.isSigned ? _certName : _importedCertName {
                    HStack(spacing: 3) {
                        Image(systemName: "signature")
                            .font(.system(size: 9))
                        Text(name)
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                }
			}
			
			Spacer()
			
			if !isEditing {
				if app.isSigned, let certInfo = certInfo {
					HStack(spacing: 4) {
						Image(systemName: "clock")
							.font(.system(size: 11))
                        Text(certInfo.formatted)
						.font(.system(size: 12))
						.fontWeight(.semibold)
					}
					.foregroundColor(.white)
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
					.background(certInfo.color)
					.clipShape(Capsule())
					.padding(.trailing, 4)
				}
				
				Image(systemName: "chevron.right")
					.foregroundColor(.secondary)
					.font(.footnote)
			}
		}
		.scaleEffect(_isSelected ? 0.98 : 1.0)
		.contentShape(Rectangle())
        // قراءة الشهادة عند الظهور للتطبيقات المستوردة فقط
        .onAppear {
            if !app.isSigned {
                _readCertNameFromIPA()
            }
        }
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			} else {
				_showActionSheet = true
			}
		}
		.confirmationDialog(
			app.name ?? .localized("Unknown"),
			isPresented: $_showActionSheet,
			titleVisibility: .visible
		) {
			if !isEditing {
				_actionSheetButtons(for: app)
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
        .sheet(isPresented: $_showCertInject) {
            CertificateInjectView(app: app) {
                // بعد الحقن مباشرة للتوقيع
                selectedSigningAppPresenting = AnyApp(base: app)
            }
        }
	}
	
	private var _desc: String {
		if let version = app.version, let id = app.identifier {
			return "\(version) • \(id)"
		} else {
			return .localized("Unknown")
		}
	}

    // MARK: - قراءة اسم الشهادة من embedded.mobileprovision داخل IPA
    private func _readCertNameFromIPA() {
        guard
            let imported = app as? Imported,
            let source = imported.source
        else { return }

        Task.detached(priority: .background) {
            let name = Self._extractSigningInfo(from: source)
            await MainActor.run {
                _importedCertName = name
            }
        }
    }

    /// يفتح الـ IPA ويقرأ embedded.mobileprovision ويستخرج اسم المطوّر/الشهادة
    private static func _extractSigningInfo(from ipaURL: URL) -> String? {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else { return nil }

        // نبحث عن embedded.mobileprovision داخل Payload/*.app/
        guard let entry = archive.first(where: {
            $0.path.contains(".app/embedded.mobileprovision")
        }) else { return nil }

        // نستخرج محتوى الملف
        var data = Data()
        _ = try? archive.extract(entry, consumer: { chunk in data.append(chunk) })
        guard !data.isEmpty else { return nil }

        // mobileprovision هو DER/CMS — الـ plist مضمّن كنص ASCII في المنتصف
        guard let text = String(data: data, encoding: .ascii) else { return nil }

        guard
            let start = text.range(of: "<?xml"),
            let end   = text.range(of: "</plist>")
        else { return nil }

        let xmlString = String(text[start.lowerBound...end.upperBound])
        guard
            let xmlData = xmlString.data(using: .utf8),
            let plist   = try? PropertyListSerialization.propertyList(from: xmlData, format: nil) as? [String: Any]
        else { return nil }

        // نرتّب الأولويات: TeamName أوضح، ثم AppIDName كبديل
        if let teamName = plist["TeamName"] as? String, !teamName.isEmpty {
            return teamName
        }
        if let appIDName = plist["AppIDName"] as? String, !appIDName.isEmpty {
            return appIDName
        }
        return nil
    }
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		let impactFeedback = UIImpactFeedbackGenerator(style: .light)
		impactFeedback.impactOccurred()
		withAnimation(.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0)) {
			if _isSelected {
				selectedApps.remove(uuid)
			} else {
				selectedApps.insert(uuid)
			}
		}
	}
}

// MARK: - Extension: View
extension LibraryCellView {
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteApp(for: app)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					UIApplication.openApp(with: id)
				}
			}
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Re-sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		} else {
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
		}
		Button(.localized("حقن الشهادة"), systemImage: "syringe") {
			_showCertInject = true
		}
	}
	
	@ViewBuilder
	private func _actionSheetButtons(for app: AppInfoPresentable) -> some View {
		if app.isSigned {
			Button(.localized("Install")) {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			if let id = app.identifier {
				Button(.localized("Open")) {
					UIApplication.openApp(with: id)
				}
			}
			Button(.localized("Re-sign")) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export")) {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		} else {
			Button(.localized("Sign & Install")) {
				selectedSigningAppPresenting = AnyApp(base: app, signAndInstall: true)
			}
			Button(.localized("Sign")) {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export")) {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		}
		Button(.localized("حقن الشهادة")) {
			_showCertInject = true
		}
		Button("الديلبات الحالية") {
			selectedAppDylibsPresenting = AnyApp(base: app)
		}
		Button(.localized("Get Info")) {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
		Button(.localized("Delete"), role: .destructive) {
			Storage.shared.deleteApp(for: app)
		}
	}
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		Group {
			if app.isSigned {
				Button {
					selectedInstallAppPresenting = AnyApp(base: app)
				} label: {
					FRExpirationPillView(
						title: .localized("Install"),
						showOverlay: _libraryCellAppearance == 0,
						expiration: certInfo
					)
				}
			} else {
				Button {
					selectedSigningAppPresenting = AnyApp(base: app)
				} label: {
					FRExpirationPillView(
						title: .localized("Sign"),
						showOverlay: true,
						expiration: nil
					)
				}
			}
		}
		.buttonStyle(.borderless)
	}
}
