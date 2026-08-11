//
//  FRAppIconView.swift
//  Feather
//
//  Created by samara on 18.04.2025.
//

import SwiftUI

struct FRAppIconView: View {
    private var _app: AppInfoPresentable
    private var _size: CGFloat
    
    init(app: AppInfoPresentable, size: CGFloat = 87) {
        self._app = app
        self._size = size
    }
    
    var body: some View {
        if let uiImage = _loadIcon() {
            Image(uiImage: uiImage)
                .appIconStyle(size: _size)
        } else {
            Image("App_Unknown")
                .appIconStyle(size: _size)
        }
    }
    
    private func _loadIcon() -> UIImage? {
        guard let iconName = _app.icon, !iconName.isEmpty else { return nil }
        
        // الأيقونة دائماً محفوظة في UUID dir بجانب الـ IPA
        // سواء كان Imported أو Signed
        if let uuidDir = Storage.shared.getUuidDirectory(for: _app) {
            let iconPath = uuidDir.appendingPathComponent(iconName)
            if let img = UIImage(contentsOfFile: iconPath.path) {
                return img
            }
        }
        
        return nil
    }
}
