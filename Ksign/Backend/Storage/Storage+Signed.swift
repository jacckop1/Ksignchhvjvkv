//
//  Storage+Signed.swift
//  Feather
//
//  Created by samara on 17.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Signed Apps
extension Storage {
	func addSigned(
		uuid: String,
		source: URL? = nil,
		certificate: CertificatePair? = nil,
		
		appName: String? = nil,
		appIdentifier: String? = nil,
		appVersion: String? = nil,
		appIcon: String? = nil,
		
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = Signed(context: context)
		
		new.uuid = uuid
		new.source = source
		new.date = Date()
		// if nil, we assume adhoc or certificate was deleted afterwards
		new.certificate = certificate
		// could possibly be nil, but thats fine.
		new.identifier = appIdentifier
		new.name = appName
		new.icon = appIcon
		new.version = appVersion
		
        saveContext()
        generator.impactOccurred()
        completion(nil)
	}
    
    // ← إضافة جديدة: جلب آخر IPA موقّع
    func getLatestSignedURL() -> URL? {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first?.source
    }

    // جلب آخر تطبيق موقّع كـ Signed object (للتثبيت المباشر بعد التوقيع)
    func getLatestSignedApp() -> Signed? {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }
}
