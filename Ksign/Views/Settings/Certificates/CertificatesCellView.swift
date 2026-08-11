//
//  CertificateCellView.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct CertificatesCellView: View {
	@State var data: Certificate?
	
	@ObservedObject var cert: CertificatePair
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 6) {
			
			NBTitleWithSubtitleView(
				title: cert.nickname ?? data?.Name ?? .localized("Unknown"),
				subtitle: data?.AppIDName ?? .localized("Unknown")
			)
			
			_certInfoPill(data: cert)
		}
		.frame(height: 80)
		.contentTransition(.opacity)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onAppear {
			withAnimation {
				data = Storage.shared.getProvisionFileDecoded(for: cert)
//                Storage.shared.revokagedCertificate(for: cert)
			}
		}
	}
}

// MARK: - Extension: View
extension CertificatesCellView {
	@ViewBuilder
	private func _certInfoPill(data: CertificatePair) -> some View {
		let pillItems = _buildPills(from: data)
        let daysLeft = _daysLeft(from: data)
		HStack(spacing: 6) {
			ForEach(pillItems.indices, id: \.hashValue) { index in
				let pill = pillItems[index]
				NBPillView(
					title: pill.title,
					icon: pill.icon,
					color: pill.color,
					index: index,
					count: pillItems.count
				)
			}
            
            // زر تجديد الشهادة - يظهر فقط إذا بقي أقل من 90 يوم
            if let days = daysLeft, days < 90 {
                Button {
                    if let url = URL(string: "https://t.me/ikira18") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("تجديد الشهادة")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.6, blue: 1.0), Color(red: 0.1, green: 0.4, blue: 0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(color: Color(red: 0.1, green: 0.4, blue: 0.9).opacity(0.35), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
            }
		}
	}
    
    private func _daysLeft(from cert: CertificatePair) -> Int? {
        guard let expiration = cert.expiration else { return nil }
        let timeLeft = expiration.timeIntervalSince(.now)
        guard timeLeft > 0 else { return 0 }
        return Int(timeLeft / 86400)
    }
	
	private func _buildPills(from cert: CertificatePair) -> [NBPillItem] {
		var pills: [NBPillItem] = []
		
		if cert.ppQCheck == true {
			pills.append(NBPillItem(title: "PPQCheck", icon: "checkmark.shield", color: .red))
		}
        
        if cert.revoked {
            pills.append(NBPillItem(title: "Revoked", icon: "xmark.octagon", color: .red))
        }
        else {
            pills.append(NBPillItem(title: "Valid", icon: "checkmark.circle", color: .green))
        }
		
		if let info = cert.expiration?.expirationInfo() {
			pills.append(NBPillItem(
				title: info.formatted,
				icon: info.icon,
				color: info.color
			))
		}
		
		return pills
	}
}
