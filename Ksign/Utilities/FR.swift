//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import Zsign
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import Security

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(file: ipa, download: download)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
                
                                try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			if !options.onlyModify {
				handler.appCertificate = certificate
			}
			handler.appIcon = icon
			
			do {
				try await handler.copy()
				try await handler.modify()
                try? await handler.clean()
				
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		guard let p12Data = try? Data(contentsOf: key) else { return false }
		return _checkP12Password(p12Data: p12Data, password: password)
	}

	/// يتحقق من كلمة مرور P12 عبر Security framework — يدعم كل الرموز بما فيها النقاط
	private static func _checkP12Password(p12Data: Data, password: String) -> Bool {
		let options: [String: Any] = [kSecImportExportPassphrase as String: password]
		var items: CFArray?
		let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
		return status == errSecSuccess
	}
	
	static func checkPasswordForCertificateData(
		p12Data: Data,
		provisionData: Data,
		password: String
	) -> Bool {
		return _checkP12Password(p12Data: p12Data, password: password)
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")

		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	#if SERVER
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					let serverDir = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server")
					let pemURL = serverDir.appendingPathComponent("server.pem")
					let crtURL = serverDir.appendingPathComponent("server.crt")
					let commonNameURL = serverDir.appendingPathComponent("commonName.txt")
					
					try FileManager.default.createDirectoryIfNeeded(at: serverDir)
					try pack.key.write(to: pemURL, atomically: true, encoding: .utf8)
					try pack.cert.write(to: crtURL, atomically: true, encoding: .utf8)
					try pack.info.domains.commonName.write(to: commonNameURL, atomically: true, encoding: .utf8)
					
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	#endif
	
	static func handleSource(
		_ urlString: String,
		showAlerts: Bool = true,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else {
			competion()
			return
		}

		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				// Storage.viewContext is a main-queue context. Never touch it from
				// URLSession's background callback.
				Storage.shared.context.perform {
					let id = data.id ?? url.absoluteString

					if !Storage.shared.sourceExists(id) {
						Storage.shared.addSource(url, repository: data, id: id) { _ in
							competion()
						}
					} else {
						if showAlerts {
							Self._showSourceAlertSafely(message: "Repository already added.")
						}
						competion()
					}
				}

			case .failure(let error):
				if showAlerts {
					Self._showSourceAlertSafely(message: error.localizedDescription)
				}
				competion()
			}
		}
	}

	/// Built-in sources are loaded during startup. At that moment a root view
	/// controller might not exist yet, so never force-unwrap the presenter.
	private static func _showSourceAlertSafely(message: String) {
		DispatchQueue.main.async {
			guard let presenter = UIApplication.topViewController() else { return }
			UIAlertController.showAlertWithOk(
				presenter,
				title: "Error",
				message: message
			)
		}
	}

}

private enum CertificateHandlerError: Error {
	case invalidCertificate
}
