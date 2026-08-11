import Foundation
import SwiftUI

struct TweakLibraryItem: Identifiable, Hashable {
    enum FileKind: String {
        case dylib
        case deb
        case framework
        case bundle
        case appExtension
        case unknown

        var title: String {
            switch self {
            case .dylib: return "Dylib"
            case .deb: return "Deb"
            case .framework: return "Framework"
            case .bundle: return "Bundle"
            case .appExtension: return "App Extension"
            case .unknown: return "File"
            }
        }

        var systemImage: String {
            switch self {
            case .dylib: return "terminal.fill"
            case .deb: return "archivebox.fill"
            case .framework: return "shippingbox.fill"
            case .bundle: return "folder.fill"
            case .appExtension: return "puzzlepiece.extension.fill"
            case .unknown: return "doc.fill"
            }
        }

        var isInjectable: Bool {
            switch self {
            case .dylib, .deb, .framework, .bundle, .appExtension:
                return true
            case .unknown:
                return false
            }
        }
    }

    let url: URL
    let name: String
    let kind: FileKind
    let fileSize: Int64
    let modificationDate: Date?

    var id: String { url.path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var subtitle: String {
        if fileSize > 0 {
            return "\(kind.title) • \(formattedSize)"
        }
        return kind.title
    }

    static func kind(for url: URL) -> FileKind {
        switch url.pathExtension.lowercased() {
        case "dylib": return .dylib
        case "deb": return .deb
        case "framework": return .framework
        case "bundle": return .bundle
        case "appex": return .appExtension
        default: return .unknown
        }
    }
}

enum TweakSortOption: String, CaseIterable, Identifiable {
    case name
    case date
    case size
    case type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date"
        case .size: return "Size"
        case .type: return "Type"
        }
    }
}
