import Foundation

public struct HTTPHeader: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Parsed request line + headers of one HTTP/1.x request.
public struct HTTPRequestHead: Sendable, Hashable {
    public let method: String
    public let rawTarget: String
    public let version: String
    public let headers: [HTTPHeader]

    public init(method: String, rawTarget: String, version: String, headers: [HTTPHeader]) {
        self.method = method
        self.rawTarget = rawTarget
        self.version = version
        self.headers = headers
    }

    /// Target without the query string (Sony appends `?product=…`).
    public var path: String {
        if let index = rawTarget.firstIndex(of: "?") {
            return String(rawTarget[rawTarget.startIndex..<index])
        }
        return rawTarget
    }

    public var query: String? {
        guard let index = rawTarget.firstIndex(of: "?") else { return nil }
        return String(rawTarget[rawTarget.index(after: index)...])
    }

    /// All values of a header, case-insensitive.
    public func values(for name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func value(for name: String) -> String? {
        values(for: name).first
    }

    /// The console asks for keep-alive on every request: honour it, the hot
    /// /pkg path would otherwise reconnect per chunk.
    public var wantsKeepAlive: Bool {
        let connection = value(for: "Connection")?.trimmingCharacters(in: .whitespaces).lowercased()
        if let connection {
            if connection == "keep-alive" { return true }
            if connection == "close" { return false }
        }
        return version.uppercased() == "HTTP/1.1"
    }

    /// Parses a raw request head (up to and including the empty line).
    public static func parse(_ text: String) -> HTTPRequestHead? {
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var headers: [HTTPHeader] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
            let value = line[line.index(after: colon)...]
            headers.append(
                HTTPHeader(
                    name: String(name).trimmingCharacters(in: .whitespaces),
                    value: String(value).trimmingCharacters(in: .whitespaces)
                )
            )
        }
        return HTTPRequestHead(
            method: String(parts[0]),
            rawTarget: String(parts[1]),
            version: parts.count > 2 ? String(parts[2]) : "HTTP/1.0",
            headers: headers
        )
    }
}

/// Serializer for the (deliberately tiny) responses of the range server.
public enum HTTPResponseHead {
    public static func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Headers", "*"),
            ("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS"),
        ]
    }

    public static func head(
        status: Int,
        reason: String,
        headers: [(String, String)],
        keepAlive: Bool
    ) -> String {
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            response += "\(name): \(value)\r\n"
        }
        response += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return response
    }

    /// Head for a 404 whose body is the 9-byte literal `not found`.
    public static func notFound(keepAlive: Bool) -> String {
        head(
            status: 404,
            reason: "Not Found",
            headers: corsHeaders() + [("Content-Length", "9")],
            keepAlive: keepAlive
        )
    }

    public static let notFoundBody = "not found"

    public static func bytesResponse(
        range: HTTPByteRange,
        keepAlive: Bool,
        extraHeaders: [(String, String)] = []
    ) -> String {
        var headers: [(String, String)] = []
        headers.append(("Content-Type", "application/octet-stream"))
        headers.append(("Content-Length", String(range.length)))
        headers.append(("Accept-Ranges", "bytes"))
        if let contentRange = range.contentRange {
            headers.append(("Content-Range", contentRange))
        }
        headers.append(contentsOf: corsHeaders())
        headers.append(contentsOf: extraHeaders)
        return head(status: range.statusCode, reason: range.reason, headers: headers, keepAlive: keepAlive)
    }
}
