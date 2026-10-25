import Foundation

/// Blocking HTTPS requests that refuse to follow a redirect to anything but HTTPS, with size
/// limits on everything they fetch. Feeds are read into memory; app downloads stream to a file.
public final class HTTPClient: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = HTTPClient()
    nonisolated(unsafe) public static var userAgent = "barkeep"

    private final class Transfer {
        var maxBytes: Int64
        var destination: URL?
        var data = Data()
        var fileURL: URL?
        var response: HTTPURLResponse?
        var error: Error?
        var tooLarge = false
        let done = DispatchSemaphore(value: 0)
        init(maxBytes: Int64, destination: URL?) {
            self.maxBytes = maxBytes
            self.destination = destination
        }
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// GETs `url` into memory. `allowFile` accepts `file://` URLs (testing only).
    public static func get(_ url: URL, maxBytes: Int = 8 * 1024 * 1024, headers: [String: String] = [:],
                           accepting statuses: Set<Int> = [200], allowFile: Bool = false) throws -> (Data, HTTPURLResponse?) {
        if url.isFileURL {
            guard allowFile else { throw BarkeepError(.feedError, "Refusing to read \(url.path): file URLs need AllowFileURLs") }
            guard let data = FileManager.default.contents(atPath: url.path) else { throw BarkeepError(.feedError, "Cannot read \(url.path)") }
            guard data.count <= maxBytes else { throw BarkeepError(.feedError, "\(url.path) is larger than \(maxBytes) bytes") }
            return (data, nil)
        }
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let transfer = try shared.run(request, maxBytes: Int64(maxBytes), destination: nil)
        guard let response = transfer.response, statuses.contains(response.statusCode) else {
            throw BarkeepError(.feedError, "Cannot download \(url.absoluteString): HTTP \(transfer.response?.statusCode ?? 0)")
        }
        return (transfer.data, response)
    }

    /// Downloads `url` to `destination`, which must not exist yet.
    public static func download(_ url: URL, to destination: URL, maxBytes: Int64, allowFile: Bool = false) throws {
        if url.isFileURL {
            guard allowFile else { throw BarkeepError(.feedError, "Refusing to read \(url.path): file URLs need AllowFileURLs") }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            guard size <= maxBytes else { throw BarkeepError(.feedError, "\(url.path) is larger than \(maxBytes) bytes") }
            try FileManager.default.copyItem(at: url, to: destination)
            return
        }
        let transfer = try shared.run(URLRequest(url: url), maxBytes: maxBytes, destination: destination)
        guard let response = transfer.response, response.statusCode == 200, transfer.fileURL != nil else {
            throw BarkeepError(.feedError, "Cannot download \(url.absoluteString): HTTP \(transfer.response?.statusCode ?? 0)")
        }
    }

    private func run(_ request: URLRequest, maxBytes: Int64, destination: URL?) throws -> Transfer {
        let url = request.url?.absoluteString ?? "?"
        guard request.url?.scheme == "https" else { throw BarkeepError(.feedError, "Refusing to download \(url) without HTTPS") }
        let transfer = Transfer(maxBytes: maxBytes, destination: destination)
        let task: URLSessionTask = destination == nil ? session.dataTask(with: request) : session.downloadTask(with: request)
        lock.withLock { transfers[task.taskIdentifier] = transfer }
        task.resume()
        transfer.done.wait()
        lock.withLock { transfers[task.taskIdentifier] = nil }
        if transfer.tooLarge { throw BarkeepError(.feedError, "\(url) is larger than \(maxBytes) bytes") }
        if let error = transfer.error { throw BarkeepError(.feedError, "Cannot download \(url): \(error.localizedDescription)") }
        return transfer
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? { lock.withLock { transfers[task.taskIdentifier] } }

    // MARK: Delegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let t = transfer(dataTask) else { return completionHandler(.cancel) }
        t.response = response as? HTTPURLResponse
        if response.expectedContentLength > t.maxBytes {
            t.tooLarge = true
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let t = transfer(dataTask) else { return }
        t.data.append(data)
        if Int64(t.data.count) > t.maxBytes {
            t.tooLarge = true
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = transfer(downloadTask) else { return }
        if totalBytesWritten > t.maxBytes || totalBytesExpectedToWrite > t.maxBytes {
            t.tooLarge = true
            downloadTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let t = transfer(downloadTask), let destination = t.destination else { return }
        t.response = downloadTask.response as? HTTPURLResponse
        guard t.response?.statusCode == 200 else { return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            t.fileURL = destination
        } catch {
            t.error = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = transfer(task) else { return }
        if t.response == nil { t.response = task.response as? HTTPURLResponse }
        if let error, !t.tooLarge { t.error = error }
        t.done.signal()
    }
}
