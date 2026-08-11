import Foundation
import UIKit

struct AppStoreImportProgressSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case connecting
        case downloading
        case processing
        case failed
    }

    let id: String
    let appName: String
    let downloadedBytes: Int64
    let totalBytes: Int64
    let progress: Double
    let phase: Phase
    let errorMessage: String?
    let retryAttempt: Int
    let retryScheduled: Bool

    var percentage: Int {
        Int((min(max(progress, 0), 1) * 100).rounded())
    }
}

extension Notification.Name {
    static let ksignAppStoreImportProgress = Notification.Name("ksign.appStoreImport.progress")
    static let ksignAppStoreImportClear = Notification.Name("ksign.appStoreImport.clear")
}

/// مدير منفصل تماماً عن DownloadManager الأساسي.
/// لا يتم إنشاء الـ singleton ولا URLSession إلا عند بدء سحب App Store فعلياً.
final class AppStorePullManager: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    static let shared = AppStorePullManager()

    private override init() {
        super.init()
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var currentURL: URL?
    private var currentPayload: AppStorePackagePayload?
    private var currentAppName: String = "تطبيق من App Store"
    private var expectedBytes: Int64 = 0
    private var downloadedBytes: Int64 = 0
    private var resumeData: Data?
    private var retryAttempt: Int = 0
    private var retryScheduled = false
    private var currentID = UUID().uuidString
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isProcessing = false

    private func makeSessionIfNeeded() -> URLSession {
        if let session { return session }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        if #available(iOS 13.0, *) {
            configuration.allowsExpensiveNetworkAccess = true
            configuration.allowsConstrainedNetworkAccess = true
        }

        let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        session = newSession
        return newSession
    }

    func start(
        url: URL,
        payload: AppStorePackagePayload,
        appName: String,
        expectedBytes: Int64?
    ) {
        cancelInternal(clearUI: false)

        currentID = UUID().uuidString
        currentURL = url
        currentPayload = payload
        currentAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "تطبيق من App Store" : appName
        self.expectedBytes = max(expectedBytes ?? 0, 0)
        downloadedBytes = 0
        resumeData = nil
        retryAttempt = 0
        retryScheduled = false
        isProcessing = false

        beginBackgroundTask()
        publish(phase: .connecting, progress: 0, error: nil)
        startTask(useResumeData: false)
    }

    func retry() {
        guard currentURL != nil, currentPayload != nil else { return }
        retryAttempt = 0
        retryScheduled = false
        isProcessing = false
        publish(phase: .connecting, progress: currentProgress, error: nil)
        beginBackgroundTask()
        startTask(useResumeData: true)
    }

    func cancel() {
        cancelInternal(clearUI: true)
    }

    private var currentProgress: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(max(Double(downloadedBytes) / Double(expectedBytes), 0), 1)
    }

    private func startTask(useResumeData: Bool) {
        let session = makeSessionIfNeeded()
        let newTask: URLSessionDownloadTask

        if useResumeData, let resumeData, !resumeData.isEmpty {
            newTask = session.downloadTask(withResumeData: resumeData)
        } else if let currentURL {
            if !useResumeData {
                downloadedBytes = 0
            }
            newTask = session.downloadTask(with: currentURL)
        } else {
            return
        }

        self.resumeData = nil
        task = newTask
        newTask.resume()
    }

    private func cancelInternal(clearUI: Bool) {
        retryScheduled = false
        task?.cancel()
        task = nil
        resumeData = nil
        isProcessing = false
        endBackgroundTask()

        if clearUI {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ksignAppStoreImportClear, object: nil)
            }
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Ksign App Store Import") { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let taskID = backgroundTask
        backgroundTask = .invalid
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    private func publish(phase: AppStoreImportProgressSnapshot.Phase, progress: Double, error: String?) {
        let snapshot = AppStoreImportProgressSnapshot(
            id: currentID,
            appName: currentAppName,
            downloadedBytes: downloadedBytes,
            totalBytes: expectedBytes,
            progress: min(max(progress, 0), 1),
            phase: phase,
            errorMessage: error,
            retryAttempt: retryAttempt,
            retryScheduled: retryScheduled
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ksignAppStoreImportProgress, object: snapshot)
        }
    }

    private func readableError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "لا يوجد اتصال بالإنترنت. تحقق من الشبكة ثم اضغط إعادة المحاولة."
            case .networkConnectionLost:
                return "انقطع اتصال الإنترنت أثناء التنزيل. اضغط إعادة المحاولة للمتابعة."
            case .timedOut:
                return "انتهت مهلة الاتصال بسبب بطء الشبكة. اضغط إعادة المحاولة."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "تعذر الوصول إلى خادم التنزيل حالياً. حاول مرة أخرى."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func isTransient(_ error: Error) -> Bool {
        let code: URLError.Code
        if let urlError = error as? URLError {
            code = urlError.code
        } else {
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return false }
            code = URLError.Code(rawValue: nsError.code)
        }

        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .resourceUnavailable
        ].contains(code)
    }

    private func scheduleRetry(after error: Error) {
        guard retryAttempt < 3 else {
            retryScheduled = false
            publish(phase: .failed, progress: currentProgress, error: readableError(error))
            endBackgroundTask()
            return
        }

        retryAttempt += 1
        retryScheduled = true
        let delay = [2.0, 5.0, 10.0][retryAttempt - 1]
        publish(phase: .connecting, progress: currentProgress, error: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.retryScheduled else { return }
            self.retryScheduled = false
            self.startTask(useResumeData: true)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard downloadTask === task else { return }

        downloadedBytes = max(totalBytesWritten, 0)
        if totalBytesExpectedToWrite > 0 {
            expectedBytes = totalBytesExpectedToWrite
        }
        let progress = expectedBytes > 0 ? Double(downloadedBytes) / Double(expectedBytes) : 0
        publish(phase: .downloading, progress: progress, error: nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard downloadTask === task,
              let payload = currentPayload else { return }

        task = nil
        retryScheduled = false
        isProcessing = true
        if downloadTask.countOfBytesExpectedToReceive > 0 {
            expectedBytes = downloadTask.countOfBytesExpectedToReceive
        }
        if downloadTask.countOfBytesReceived > 0 {
            downloadedBytes = downloadTask.countOfBytesReceived
        }
        publish(phase: .processing, progress: 1, error: nil)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ksign-AppStore-\(UUID().uuidString).ipa")

        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try AppStorePackageFinalizer.finalize(archiveURL: destination, payload: payload)

            FR.handlePackageFile(destination) { [weak self] error in
                guard let self else { return }
                try? FileManager.default.removeItem(at: destination)
                self.isProcessing = false
                self.endBackgroundTask()

                if let error {
                    self.publish(
                        phase: .failed,
                        progress: 1,
                        error: "فشل إضافة التطبيق إلى التطبيقات غير الموقعة: \(error.localizedDescription)"
                    )
                } else {
                    NotificationCenter.default.post(name: .ksignAppStoreImportClear, object: nil)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            isProcessing = false
            endBackgroundTask()
            publish(
                phase: .failed,
                progress: 1,
                error: "تعذر تجهيز حزمة App Store: \(error.localizedDescription)"
            )
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let downloadTask = task as? URLSessionDownloadTask,
              downloadTask === self.task,
              !isProcessing else { return }

        self.task = nil
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty {
            resumeData = data
        }

        if isTransient(error) {
            scheduleRetry(after: error)
        } else {
            retryScheduled = false
            publish(phase: .failed, progress: currentProgress, error: readableError(error))
            endBackgroundTask()
        }
    }
}
