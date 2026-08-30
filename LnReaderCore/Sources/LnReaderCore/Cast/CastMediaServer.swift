import Foundation
import Network

/// Tiny HTTP server that makes the current book reachable by a Cast receiver —
/// the iOS port of Android's CastMediaServer.
///
/// A Chromecast pulls media itself over HTTP; it can't read this device's
/// files. While a cast session is active the app runs this server and the cast
/// media items point at it: `/t/<token>/book/<id>` streams the m4b (with Range
/// support, required for seeking) and `/t/<token>/cover/<id>` serves the cover
/// for the TV screen. Anything not carrying the per-process random token gets
/// a 404, so other devices on the network can't browse the library.
public final class CastMediaServer: @unchecked Sendable {
    public struct Resource: Sendable {
        public let fileURL: URL
        public let mimeType: String

        public init(fileURL: URL, mimeType: String) {
            self.fileURL = fileURL
            self.mimeType = mimeType
        }
    }

    /// Maps (kind, id) — e.g. ("book", bookId) — to the file to serve, or nil for 404.
    public typealias ResourceProvider = @Sendable (String, String) -> Resource?

    private let provider: ResourceProvider
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "cast-media-server")
    private var listener: NWListener?

    public private(set) var port: UInt16?

    public init(provider: @escaping ResourceProvider) {
        self.provider = provider
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener?.port?.rawValue
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        // Wait briefly for the port so url(kind:id:) works right after start.
        let deadline = Date().addingTimeInterval(2)
        while port == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// URL a receiver on the same network should fetch from, or nil when not reachable.
    public func url(kind: String, id: String) -> URL? {
        guard let port, let ip = Self.deviceIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)/t/\(token)/\(kind)/\(id)")
    }

    /// Loopback URL for tests.
    public func localURL(kind: String, id: String) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/t/\(token)/\(kind)/\(id)")
    }

    /// The device's site-local IPv4 — the address a receiver on the same Wi-Fi can reach.
    private static func deviceIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (current.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  (current.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let head = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: head, on: connection)
        }
    }

    private func respond(to requestHead: String, on connection: NWConnection) {
        let lines = requestHead.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").components(separatedBy: " ")
        guard requestParts.count >= 2 else { return connection.cancel() }
        let method = requestParts[0]
        let path = requestParts[1]
        guard method == "GET" || method == "HEAD" else {
            return send(status: "405 Method Not Allowed", headers: [:], body: nil, on: connection)
        }

        let segments = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/")
        guard segments.count == 4, segments[0] == "t", segments[1] == token,
              let resource = provider(segments[2], segments[3]),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resource.fileURL.path),
              let total = attributes[.size] as? Int64 else {
            return send(status: "404 Not Found", headers: ["Content-Type": "text/plain"],
                        body: Data("Not found".utf8), on: connection)
        }

        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }?
            .dropFirst("range:".count)
            .trimmingCharacters(in: .whitespaces)
        let range = Self.parseRange(rangeHeader, total: total)

        var headers = [
            "Content-Type": resource.mimeType,
            "Accept-Ranges": "bytes",
            "Connection": "close",
        ]
        let status: String
        let start: Int64
        let length: Int64
        if let range {
            status = "206 Partial Content"
            start = range.lowerBound
            length = range.upperBound - range.lowerBound + 1
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(total)"
        } else {
            status = "200 OK"
            start = 0
            length = total
        }
        headers["Content-Length"] = "\(length)"

        if method == "HEAD" {
            return send(status: status, headers: headers, body: nil, on: connection)
        }
        sendFile(
            status: status, headers: headers, fileURL: resource.fileURL,
            offset: start, length: length, on: connection)
    }

    /// Handles the `bytes=start-` and `bytes=start-end` forms Cast receivers send.
    static func parseRange(_ header: String?, total: Int64) -> ClosedRange<Int64>? {
        guard let header, total > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.components(separatedBy: "-")
        guard parts.count == 2, let start = Int64(parts[0]), start >= 0, start < total else { return nil }
        let end = Int64(parts[1]).map { min($0, total - 1) } ?? (total - 1)
        guard end >= start else { return nil }
        return start ... end
    }

    private func send(status: String, headers: [String: String], body: Data?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        var allHeaders = headers
        if let body { allHeaders["Content-Length"] = "\(body.count)" }
        for (key, value) in allHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if let body { payload += body }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendFile(
        status: String, headers: [String: String], fileURL: URL,
        offset: Int64, length: Int64, on connection: NWConnection
    ) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return send(status: "404 Not Found", headers: [:], body: nil, on: connection)
        }
        var head = "HTTP/1.1 \(status)\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            self?.streamChunks(handle: handle, offset: offset, remaining: length, on: connection)
        })
    }

    private func streamChunks(handle: FileHandle, offset: Int64, remaining: Int64, on connection: NWConnection) {
        let chunkSize: Int64 = 1 << 20
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            try? handle.close()
            connection.cancel()
            return
        }
        let take = Int(min(chunkSize, remaining))
        guard let chunk = try? handle.read(upToCount: take), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.streamChunks(
                handle: handle,
                offset: offset + Int64(chunk.count),
                remaining: remaining - Int64(chunk.count),
                on: connection)
        })
    }
}
