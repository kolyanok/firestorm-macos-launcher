import Foundation
import Darwin

/// Resumable, bounded HTTP transfer. A 206 response may contain only a prefix
/// of the requested range; each completed response advances the next request.
/// The caller still checks the complete file's pinned hash/BLTE checksums.
final class StreamDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct RequestContext {
        let identifier: Int
        let start: Int64
        let end: Int64
    }

    private struct ByteRange {
        let start: Int64
        let end: Int64
        let total: Int64

        static func parse(_ text: String) -> ByteRange? {
            let fields = text.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
            let sizes = fields[1].split(separator: "/", omittingEmptySubsequences: false)
            guard sizes.count == 2, let total = Int64(sizes[1]), total > 0 else { return nil }
            let bounds = sizes[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start >= 0, end >= start, end < total else { return nil }
            return ByteRange(start: start, end: end, total: total)
        }
    }

    private let url: URL
    private let destination: URL
    private let expected: Int64
    private let cancellation: InstallCancellation
    private let objectName: String
    private let report: (Int64) -> Void
    private let completion = DispatchSemaphore(value: 0)
    private let chunkSize: Int64 = 8 * 1024 * 1024
    private var partial: URL { destination.appendingPathExtension("part") }

    // Only perform() sets a new context, before resuming its task. Delegate
    // callbacks run on one serial queue; perform() reads their final state only
    // after the completion semaphore. No callback changes state after signalling.
    private var context: RequestContext?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var responseAccepted = false
    private var responseStatus: Int?
    private var responseEndExclusive: Int64?
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(url: URL, destination: URL, expected: Int64, cancellation: InstallCancellation,
         objectName: String, report: @escaping (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.expected = expected
        self.cancellation = cancellation
        self.objectName = objectName
        self.report = report
    }

    func perform() throws {
        guard expected > 0 else { throw problem(L("the pinned file size is invalid")) }
        try cancellation.check()
        try LauncherCore.ensureMutablePath(partial, root: destination.deletingLastPathComponent())
        let descriptor = Darwin.open(partial.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw problem(L("cannot open the partial download")) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              attributes.st_uid == getuid(), attributes.st_nlink == 1,
              attributes.st_size >= 0 else {
            Darwin.close(descriptor)
            throw problem(L("the partial download is not a private regular file"))
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? self.handle?.close(); self.handle = nil }
        if attributes.st_size > expected {
            try handle?.truncate(atOffset: 0)
            record(LF("Discarded oversized partial file: %@ bytes; expected %@.", String(attributes.st_size), String(expected)))
        }
        guard let output = self.handle else { throw problem(L("cannot open the partial download")) }
        let end = try output.seekToEnd()
        guard end <= UInt64(expected) else { throw problem(L("the partial download exceeds the pinned size")) }
        received = Int64(end)
        report(received)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.invalidateAndCancel() }

        while received < expected {
            try cancellation.check()
            try receiveChunk(using: session)
        }
        try cancellation.check()
        try output.synchronize()
        try output.close()
        self.handle = nil
        try FileManager.default.moveItem(at: partial, to: destination)
        record(LF("Complete: %@/%@ bytes. Awaiting content verification.", String(received), String(expected)))
        report(received)
    }

    private func receiveChunk(using session: URLSession) throws {
        let start = received
        let end = start + min(chunkSize, expected - start) - 1
        responseAccepted = false
        responseStatus = nil
        responseEndExclusive = nil
        failure = nil

        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("FirestormMacLauncher/1.1.9", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        context = RequestContext(identifier: task.taskIdentifier, start: start, end: end)
        cancellation.attach(task)
        defer { cancellation.attach(nil) }
        // Even a task cancelled during attach must be resumed and allowed to
        // complete its callbacks before the file handle can be closed.
        task.resume()
        while completion.wait(timeout: .now() + 1) == .timedOut {
            if cancellation.isCancelled { task.cancel() }
        }
        try cancellation.check()
        if let failure { throw failure }
        guard responseAccepted else { throw problem(L("the CDN did not return a usable HTTP response")) }
        if let responseEndExclusive {
            guard received == responseEndExclusive else {
                throw problem(LF("HTTP 206 ended at byte %@; its range promised bytes through %@. The partial file is saved", String(received), String(responseEndExclusive - 1)))
            }
        } else {
            // A 200 response ignored Range. It was restarted at zero and must
            // contain the complete pinned object; otherwise another 200 would
            // repeatedly reset progress instead of actually resuming.
            guard received == expected else {
                throw problem(LF("HTTP 200 ended after %@ bytes; expected %@. The CDN did not provide a complete object", String(received), String(expected)))
            }
        }
        guard received > start else { throw problem(L("the CDN response made no download progress")) }
        record(LF("Response complete: HTTP %@, received=%@/%@.", String(responseStatus ?? 0), String(received), String(expected)))
        report(received)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let context, context.identifier == dataTask.taskIdentifier else {
            completionHandler(.cancel)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            failure = problem(L("the CDN returned a non-HTTP response"))
            completionHandler(.cancel)
            return
        }
        responseStatus = response.statusCode
        let rawRange = response.value(forHTTPHeaderField: "Content-Range") ?? "none"
        let rawLength = response.value(forHTTPHeaderField: "Content-Length") ?? "unknown"
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity"
        record(LF("HTTP %@, request=%@-%@, Content-Range=%@, Content-Length=%@, Content-Encoding=%@, expected=%@.", String(response.statusCode), String(context.start), String(context.end), rawRange, rawLength, encoding, String(expected)))

        do {
            switch response.statusCode {
            case 206:
                guard let range = ByteRange.parse(rawRange), range.start == context.start, range.total == expected else {
                    throw problem(LF("HTTP 206 returned Content-Range '%@' for requested offset %@ and pinned total %@", rawRange, String(context.start), String(expected)))
                }
                // Offsets apply to the exact encoded object, not a separately
                // HTTP-compressed representation. A compressed ranged response
                // cannot safely be appended to the existing on-disk bytes.
                guard encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity" else {
                    throw problem(LF("HTTP 206 used Content-Encoding '%@' despite the identity request. The partial file is saved", encoding))
                }
                responseEndExclusive = range.end + 1
            case 200:
                // A server may ignore Range. Reset only this partial object and
                // accept its complete body; URLSession may decode HTTP encoding.
                if received != 0 {
                    try handle?.truncate(atOffset: 0)
                    try handle?.seek(toOffset: 0)
                    received = 0
                    record(L("HTTP 200 ignored Range; restarted this object from byte zero."))
                }
                responseEndExclusive = nil
            case 416:
                // Keep the resumable file but reset its stale offset for the
                // caller's next bounded retry. Other downloaded objects remain.
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
                received = 0
                throw problem(LF("HTTP 416 rejected the saved offset %@; the next attempt will restart this object", String(context.start)))
            default:
                throw problem(LF("the CDN returned HTTP %@, Content-Range '%@', Content-Length %@. The partial file is saved", String(response.statusCode), rawRange, rawLength))
            }
            // Content-Length describes this HTTP response and may be adjusted
            // by transport decoding. It is diagnostic, not the whole-object
            // size. Count actual bytes and validate Range + final checksums.
            responseAccepted = true
            completionHandler(.allow)
        } catch {
            failure = error
            record(LF("Rejected response: %@", error.localizedDescription))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard context?.identifier == dataTask.taskIdentifier else { dataTask.cancel(); return }
        do {
            guard responseAccepted, let handle else { throw problem(L("received data before a valid HTTP response")) }
            let maximum = min(expected, responseEndExclusive ?? expected)
            guard received <= maximum, Int64(data.count) <= maximum - received else {
                throw problem(LF("HTTP %@ sent bytes beyond its validated range: current %@, chunk %@, limit %@", String(responseStatus ?? 0), String(received), String(data.count), String(maximum)))
            }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                report(received)
            }
        } catch {
            if failure == nil { failure = error }
            record(LF("Transfer interrupted: %@; received=%@/%@.", error.localizedDescription, String(received), String(expected)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard context?.identifier == task.taskIdentifier else { return }
        if failure == nil, let error {
            failure = problem(LF("HTTP %@ stopped at %@/%@ bytes: %@", String(responseStatus ?? 0), String(received), String(expected), error.localizedDescription))
        }
        if let failure { record(LF("Request failed: %@", failure.localizedDescription)) }
        // This is the last action: perform() may start the next request after it.
        completion.signal()
    }

    private func problem(_ message: String) -> LauncherFailure {
        LauncherFailure(LF("Downloading %@ [%@]: %@.", objectName, destination.lastPathComponent, message))
    }

    private func record(_ event: String) {
        let log = destination.deletingLastPathComponent().appendingPathComponent("download.log")
        let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              attributes.st_uid == getuid(), attributes.st_nlink == 1 else { return }
        let clean = event.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(destination.lastPathComponent)] \(clean.prefix(3500))\n"
        let bytes = Data(line.utf8)
        let maximum: off_t = 1024 * 1024
        if attributes.st_size < 0 || attributes.st_size + off_t(bytes.count) > maximum {
            guard Darwin.ftruncate(descriptor, 0) == 0 else { return }
        }
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { break }
                written += result
            }
        }
    }
}
