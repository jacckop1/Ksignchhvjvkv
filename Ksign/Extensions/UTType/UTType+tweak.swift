import UniformTypeIdentifiers

extension UTType {
    static var dylib: UTType {
        UTType(filenameExtension: "dylib", conformingTo: .data) ?? .data
    }

    static var deb: UTType {
        UTType(filenameExtension: "deb", conformingTo: .archive) ?? .archive
    }

    static var framework: UTType {
        UTType(filenameExtension: "framework", conformingTo: .package) ?? .package
    }

    static var tweakFiles: [UTType] {
        [.dylib, .deb, .framework]
    }

    static var tweakPickerFiles: [UTType] {
        [.dylib, .deb, .framework]
    }

    static var ipaFiles: [UTType] {
        [.ipa, .tipa, .zip, .archive]
    }
}
