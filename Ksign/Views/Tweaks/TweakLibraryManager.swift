import Foundation
import SwiftUI
import ZIPFoundation

struct TweakExtractionCandidate: Identifiable, Hashable {
    let sourceURL: URL
    let name: String
    let kind: TweakLibraryItem.FileKind
    let fileSize: Int64

    var id: String { sourceURL.path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var subtitle: String {
        if fileSize > 0 {
            return "\(kind.title) • \(formattedSize)"
        }
        return kind.title
    }
}

struct TweakExtractionSession: Identifiable {
    let id = UUID()
    let sourceName: String
    let temporaryDirectory: URL?
    let candidates: [TweakExtractionCandidate]
}

@MainActor
final class TweakLibraryManager: ObservableObject {
    @Published private(set) var items: [TweakLibraryItem] = []
    @Published var isWorking = false
    @Published var statusMessage: String?
    @Published var downloadProgress: Double?
    @Published var downloadProgressText: String?

    nonisolated static let supportedTweakExtensions = Set(["dylib", "deb", "framework"])
    nonisolated static let supportedIPAExtensions = Set(["ipa", "tipa", "zip"])

    private let fileManager = FileManager.default

    private var tweaksDirectory: URL {
        fileManager.tweaks
    }

    private let allowedExtensions = TweakLibraryManager.supportedTweakExtensions

    func load() {
        do {
            try fileManager.createDirectoryIfNeeded(at: tweaksDirectory)
            let urls = try fileManager.contentsOfDirectory(
                at: tweaksDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            items = urls
                .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
                .map(makeItem)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            statusMessage = error.localizedDescription
            items = []
        }
    }

    func filteredItems(searchText: String, sortOption: TweakSortOption, ascending: Bool) -> [TweakLibraryItem] {
        let searched: [TweakLibraryItem]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searched = items
        } else {
            searched = items.filter { item in
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.kind.title.localizedCaseInsensitiveContains(searchText)
            }
        }

        let sorted = searched.sorted { lhs, rhs in
            switch sortOption {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .date:
                return (lhs.modificationDate ?? .distantPast) < (rhs.modificationDate ?? .distantPast)
            case .size:
                return lhs.fileSize < rhs.fileSize
            case .type:
                if lhs.kind.title == rhs.kind.title {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.kind.title.localizedCaseInsensitiveCompare(rhs.kind.title) == .orderedAscending
            }
        }

        return ascending ? sorted : Array(sorted.reversed())
    }

    func importTweaks(from urls: [URL], autoInject: Bool = false) {
        guard !urls.isEmpty else { return }

        isWorking = true
        statusMessage = nil

        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) { [allowedExtensions] in
                    try Self.copyTweaks(
                        from: urls,
                        to: FileManager.default.tweaks,
                        allowedExtensions: allowedExtensions
                    )
                }.value

                if autoInject {
                    addToAutoInject(imported)
                }

                statusMessage = imported.isEmpty
                    ? "لم يتم العثور على ملفات تويك مدعومة. الصيغ المدعومة: .dylib, .deb, .framework"
                    : "تم استيراد \(imported.count) ملف تويك."
                isWorking = false
                load()
            } catch {
                statusMessage = error.localizedDescription
                isWorking = false
                load()
            }
        }
    }

    func downloadAndPrepareImport(from urlString: String, autoInject: Bool = false) async -> TweakExtractionSession? {
        let clean = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let normalized: String
        if clean.lowercased().hasPrefix("http://") || clean.lowercased().hasPrefix("https://") {
            normalized = clean
        } else {
            normalized = "https://\(clean)"
        }

        guard let url = URL(string: normalized) else {
            statusMessage = "الرابط غير صحيح."
            return nil
        }

        isWorking = true
        downloadProgress = 0
        downloadProgressText = "بدء التحميل..."
        statusMessage = nil

        do {
            let downloaded = try await downloadFileWithProgress(from: url)
            let tmpURL = try moveDownloadedFile(downloaded.fileURL, response: downloaded.response, originalURL: url)
            let ext = tmpURL.pathExtension.lowercased()

            if Self.supportedIPAExtensions.contains(ext) {
                downloadProgress = nil
                downloadProgressText = nil
                statusMessage = "اكتمل التحميل. جارٍ استخراج محتويات IPA..."
                isWorking = false
                return await prepareExtractionSession(from: tmpURL, cleanupSourceAfterPreparation: true)
            } else if Self.supportedTweakExtensions.contains(ext) {
                downloadProgress = nil
                downloadProgressText = nil
                isWorking = false
                importTweaks(from: [tmpURL], autoInject: autoInject)
                return nil
            } else {
                statusMessage = "الرابط غير مدعوم. استخدم رابط مباشر لملف .dylib أو .deb أو .framework أو .ipa."
                downloadProgress = nil
                downloadProgressText = nil
                isWorking = false
                try? FileManager.default.removeItem(at: tmpURL)
                return nil
            }
        } catch {
            downloadProgress = nil
            downloadProgressText = nil
            statusMessage = error.localizedDescription
            isWorking = false
            return nil
        }
    }

    private func downloadFileWithProgress(from url: URL) async throws -> (fileURL: URL, response: URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
            var continuation: CheckedContinuation<(fileURL: URL, response: URLResponse), Error>?
            var temporaryCopyURL: URL?
            let progressHandler: @MainActor (Double, Int64, Int64) -> Void

            init(progressHandler: @escaping @MainActor (Double, Int64, Int64) -> Void) {
                self.progressHandler = progressHandler
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                guard totalBytesExpectedToWrite > 0 else { return }
                let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
                Task { @MainActor in
                    progressHandler(progress, totalBytesWritten, totalBytesExpectedToWrite)
                }
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                let copyURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("KiraTweakDownload_\(UUID().uuidString).tmp")
                do {
                    try? FileManager.default.removeItem(at: copyURL)
                    try FileManager.default.copyItem(at: location, to: copyURL)
                    temporaryCopyURL = copyURL
                } catch {
                    continuation?.resume(throwing: error)
                    continuation = nil
                }
            }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didCompleteWithError error: Error?
            ) {
                if let error {
                    continuation?.resume(throwing: error)
                    continuation = nil
                    return
                }

                guard let temporaryCopyURL, let response = task.response else {
                    continuation?.resume(
                        throwing: NSError(
                            domain: "KiraTweaks",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "فشل حفظ الملف المحمّل."]
                        )
                    )
                    continuation = nil
                    return
                }

                continuation?.resume(returning: (fileURL: temporaryCopyURL, response: response))
                continuation = nil
            }
        }

        let delegate = DownloadDelegate { [weak self] progress, written, expected in
            guard let self else { return }
            self.downloadProgress = progress
            self.downloadProgressText = Self.formatDownloadProgress(progress: progress, written: written, expected: expected)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    private func moveDownloadedFile(_ downloadedURL: URL, response: URLResponse, originalURL: URL) throws -> URL {
        let fileName = Self.bestDownloadFileName(response: response, originalURL: originalURL)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName.isEmpty ? "KiraTweak_\(UUID().uuidString)" : fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        return destination
    }

    nonisolated private static func bestDownloadFileName(response: URLResponse, originalURL: URL) -> String {
        let responseName = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let urlName = originalURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlExtension = originalURL.pathExtension.lowercased()

        if !responseName.isEmpty {
            let responseExtension = (responseName as NSString).pathExtension.lowercased()
            if !responseExtension.isEmpty {
                return responseName
            }
            if !urlExtension.isEmpty {
                return responseName + "." + urlExtension
            }
            return responseName
        }

        if !urlName.isEmpty {
            return urlName
        }

        return "KiraTweak_\(UUID().uuidString)"
    }

    nonisolated private static func formatDownloadProgress(progress: Double, written: Int64, expected: Int64) -> String {
        let percentage = Int((progress * 100).rounded())
        let writtenText = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
        let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return "جارٍ التحميل... \(percentage)% • \(writtenText) / \(expectedText)"
    }

    func prepareExtractionSession(from appOrIPAURL: URL, cleanupSourceAfterPreparation: Bool = false) async -> TweakExtractionSession? {
        isWorking = true
        statusMessage = nil

        do {
            let session = try await Task.detached(priority: .userInitiated) { [allowedExtensions] in
                try Self.makeExtractionSession(
                    from: appOrIPAURL,
                    allowedExtensions: allowedExtensions,
                    cleanupSourceAfterPreparation: cleanupSourceAfterPreparation
                )
            }.value

            isWorking = false

            if session.candidates.isEmpty {
                statusMessage = "لم يتم العثور على أي تويك داخل هذا الملف."
                cleanupExtractionSession(session)
                return nil
            }

            statusMessage = "تم العثور على \(session.candidates.count) ملف. اختر الملفات التي تريد استخراجها."
            return session
        } catch {
            statusMessage = error.localizedDescription
            isWorking = false
            return nil
        }
    }

    func importSelectedTweaks(
        _ candidates: [TweakExtractionCandidate],
        from session: TweakExtractionSession,
        autoInject: Bool = false
    ) {
        guard !candidates.isEmpty else {
            cleanupExtractionSession(session)
            return
        }

        isWorking = true
        statusMessage = nil

        Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) { [allowedExtensions] in
                    try Self.copyTweaks(
                        from: candidates.map(\.sourceURL),
                        to: FileManager.default.tweaks,
                        allowedExtensions: allowedExtensions
                    )
                }.value

                if autoInject {
                    addToAutoInject(imported)
                }

                cleanupExtractionSession(session)
                statusMessage = imported.isEmpty ? "لم يتم استخراج أي ملف." : "تم استخراج \(imported.count) ملف تويك."
                isWorking = false
                load()
            } catch {
                cleanupExtractionSession(session)
                statusMessage = error.localizedDescription
                isWorking = false
                load()
            }
        }
    }

    func cleanupExtractionSession(_ session: TweakExtractionSession) {
        if let temporaryDirectory = session.temporaryDirectory {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
    }

    /// Direct extraction without preview. Kept for older callers.
    func extractTweaks(from appOrIPAURL: URL, autoInject: Bool = false) async throws {
        guard let session = await prepareExtractionSession(from: appOrIPAURL) else { return }
        importSelectedTweaks(session.candidates, from: session, autoInject: autoInject)
    }

    func delete(_ item: TweakLibraryItem) {
        do {
            try fileManager.removeItem(at: item.url)
            removeFromAutoInject([item.url])
            load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func delete(_ items: [TweakLibraryItem]) {
        for item in items {
            try? fileManager.removeItem(at: item.url)
        }
        removeFromAutoInject(items.map(\.url))
        load()
    }

    func setAutoInject(_ item: TweakLibraryItem, enabled: Bool) {
        if enabled {
            addToAutoInject([item.url])
        } else {
            removeFromAutoInject([item.url])
        }
        objectWillChange.send()
    }

    func isAutoInjected(_ item: TweakLibraryItem) -> Bool {
        OptionsManager.shared.options.injectionFiles.contains(item.url)
    }

    private func addToAutoInject(_ urls: [URL]) {
        var options = OptionsManager.shared.options
        for url in urls where !options.injectionFiles.contains(url) {
            options.injectionFiles.append(url)
        }
        OptionsManager.shared.options = options
        OptionsManager.shared.saveOptions()
    }

    private func removeFromAutoInject(_ urls: [URL]) {
        var options = OptionsManager.shared.options
        options.injectionFiles.removeAll { urls.contains($0) }
        OptionsManager.shared.options = options
        OptionsManager.shared.saveOptions()
    }

    private func makeItem(_ url: URL) -> TweakLibraryItem {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        let size = Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? directorySize(url))

        return TweakLibraryItem(
            url: url,
            name: url.lastPathComponent,
            kind: TweakLibraryItem.kind(for: url),
            fileSize: size,
            modificationDate: values?.contentModificationDate
        )
    }

    private func directorySize(_ url: URL) -> Int {
        Self.directorySize(url)
    }

    nonisolated private static func copyTweaks(
        from urls: [URL],
        to destinationDirectory: URL,
        allowedExtensions: Set<String>
    ) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectoryIfNeeded(at: destinationDirectory)

        var imported: [URL] = []
        for source in urls {
            let ext = source.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }

            let destination = uniqueDestination(
                for: source.lastPathComponent,
                in: destinationDirectory
            )

            var didStartAccessing = false
            if fileManager.isFileFromFileProvider(at: source) {
                didStartAccessing = source.startAccessingSecurityScopedResource()
            }
            defer {
                if didStartAccessing {
                    source.stopAccessingSecurityScopedResource()
                }
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try fileManager.copyItem(at: source, to: destination)
            } else {
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: .atomic)
            }
            imported.append(destination)
        }
        return imported
    }

    nonisolated private static func makeExtractionSession(
        from appOrIPAURL: URL,
        allowedExtensions: Set<String>,
        cleanupSourceAfterPreparation: Bool
    ) throws -> TweakExtractionSession {
        let fileManager = FileManager.default
        let ext = appOrIPAURL.pathExtension.lowercased()
        let sourceName = appOrIPAURL.lastPathComponent
        let tmpRoot = fileManager.temporaryDirectory.appendingPathComponent("KiraTweakPreview_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectoryIfNeeded(at: tmpRoot)

        do {
            let scanRoot: URL

            if supportedIPAExtensions.contains(ext) {
                let extractedDirectory = tmpRoot.appendingPathComponent("Extracted", isDirectory: true)
                try fileManager.createDirectoryIfNeeded(at: extractedDirectory)
                try extractArchive(appOrIPAURL, to: extractedDirectory)
                scanRoot = extractedDirectory
            } else {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: appOrIPAURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    scanRoot = appOrIPAURL
                } else if allowedExtensions.contains(ext) {
                    let candidates = [makeCandidate(for: appOrIPAURL)]
                    if cleanupSourceAfterPreparation {
                        // Direct tweak links are imported immediately by the caller, not previewed.
                    }
                    return TweakExtractionSession(sourceName: sourceName, temporaryDirectory: nil, candidates: candidates)
                } else {
                    scanRoot = appOrIPAURL
                }
            }

            let candidates = try findTweakCandidates(in: scanRoot, allowedExtensions: allowedExtensions)
            if cleanupSourceAfterPreparation {
                try? fileManager.removeItem(at: appOrIPAURL)
            }

            return TweakExtractionSession(
                sourceName: sourceName,
                temporaryDirectory: tmpRoot,
                candidates: candidates
            )
        } catch {
            try? fileManager.removeItem(at: tmpRoot)
            if cleanupSourceAfterPreparation {
                try? fileManager.removeItem(at: appOrIPAURL)
            }
            throw error
        }
    }

    nonisolated private static func extractArchive(_ ipaURL: URL, to destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        let archive = try Archive(url: ipaURL, accessMode: .read)
        for entry in archive {
            guard !entry.path.hasPrefix("__MACOSX") else { continue }
            let destination = destinationDirectory.appendingPathComponent(entry.path)
            try fileManager.createDirectoryIfNeeded(at: destination.deletingLastPathComponent())
            _ = try? archive.extract(entry, to: destination)
        }
    }

    nonisolated private static func findTweakCandidates(
        in sourceDirectory: URL,
        allowedExtensions: Set<String>
    ) throws -> [TweakExtractionCandidate] {
        let fileManager = FileManager.default
        var urls: [URL] = []

        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }

            if ext == "dylib" || ext == "deb" {
                urls.append(url)
                continue
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                urls.append(url)
                enumerator.skipDescendants()
            }
        }

        return urls
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map(makeCandidate)
    }

    nonisolated private static func makeCandidate(for url: URL) -> TweakExtractionCandidate {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        let size = Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? directorySize(url))
        return TweakExtractionCandidate(
            sourceURL: url,
            name: url.lastPathComponent,
            kind: TweakLibraryItem.kind(for: url),
            fileSize: size
        )
    }

    nonisolated private static func directorySize(_ url: URL) -> Int {
        let fileManager = FileManager.default
        var size = 0
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            size += values?.fileSize ?? 0
        }
        return size
    }

    nonisolated private static func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let original = directory.appendingPathComponent(fileName)
        if !fileManager.fileExists(atPath: original.path) {
            return original
        }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        for index in 1...9999 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base)-\(index)"
            } else {
                candidateName = "\(base)-\(index).\(ext)"
            }
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
    }
}
