//
//  SourcesCellView.swift
//  Feather
//
//  Created by samara on 1.05.2025.
//
import SwiftUI
import NimbleViews
import NukeUI

// MARK: - View
struct SourcesCellView: View {
    var source: AltSource
    
    // MARK: Body
    var body: some View {
        FRIconCellView(
            title: source.name ?? .localized("Unknown"),
            subtitle: "",
            iconUrl: source.iconURL
        )
        .swipeActions {
            _actions(for: source)
        }
        .contextMenu {
            Divider()
            _actions(for: source)
        }
    }
}

// MARK: - Extension: View
extension SourcesCellView {
    @ViewBuilder
    private func _actions(for source: AltSource) -> some View {
        Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
            Storage.shared.deleteSource(for: source)
        }
    }
}
