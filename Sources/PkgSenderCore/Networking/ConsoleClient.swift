import Foundation

/// Reply of a console request that may never reach the console at all.
public struct ConsoleReply: Sendable, Hashable {
    /// Payload-level success (`"success"` / `"ok"` / `"started"` in the body).
    public let ok: Bool
    /// Raw response body; empty when nothing answered.
    public let body: String
    /// False when neither port answered — `body` is then only a message.
    public let reached: Bool

    public init(ok: Bool, body: String, reached: Bool) {
        self.ok = ok
        self.body = body
        self.reached = reached
    }

    public init(unreachable message: String) {
        self.init(ok: false, body: message, reached: false)
    }
}

/// `/api/status` answer of the receiver.
public struct ConsoleStatus: Sendable, Equatable {
    /// The payload exposes a `busy` field; older WebUI payloads do not.
    public let supported: Bool
    public let busy: Bool
}

/// Receiver-side pull-copy progress, also from `/api/status`.
public struct ConsolePullProgress: Sendable, Equatable {
    public let active: Bool
    public let name: String
    public let receivedBytes: Int64
    public let totalBytes: Int64
    public let paused: Bool
}

/// `/api/files/stat` answer: does a remote file exist and how big is it.
public struct RemoteFileStatus: Sendable, Equatable {
    public let exists: Bool
    public let size: Int64
}

/// Minimal RPI-compatible client for the receiver on the console
/// (port 12800, PS4 fallback 9090).
///
/// Every call tries the ports in order and uses the first one that answers,
/// so the same client serves PS5 receivers and PS4 RPI/GoldHEN alike.
public struct ConsoleClient: Sendable {
    public static let primaryPort = 12800
    public static let fallbackPort = 9090
    public static let defaultPorts = [primaryPort, fallbackPort]
    public static let defaultTimeout: TimeInterval = 15

    public let session: URLSession
    public let ports: [Int]
    public let timeout: TimeInterval

    public init(
        session: URLSession = .pkgSenderDefault,
        ports: [Int] = defaultPorts,
        timeout: TimeInterval = defaultTimeout
    ) {
        self.session = session
        self.ports = ports
        self.timeout = timeout
    }

    // MARK: - Probes

    /// `GET /api` — the receiver answers "Unsupported method"/"fail" for GET.
    public func isOnline(host: String, timeout seconds: TimeInterval? = nil) async -> Bool {
        guard let body = await get(host: host, path: "/api", timeout: seconds ?? 3) else { return false }
        return body.contains("Unsupported method") && body.contains("fail")
    }

    /// `GET /api/status` — busy flag of the console's install queue.
    public func status(host: String, timeout seconds: TimeInterval? = nil) async -> ConsoleStatus? {
        guard let body = await get(host: host, path: "/api/status", timeout: seconds ?? 10) else { return nil }
        guard body.contains("busy") else { return ConsoleStatus(supported: false, busy: false) }
        return ConsoleStatus(supported: true, busy: JSONScalarReader.bool(body, key: "busy"))
    }

    /// Pull-copy progress out of `GET /api/status`.
    public func pullProgress(host: String, timeout seconds: TimeInterval? = nil) async -> ConsolePullProgress? {
        guard let body = await get(host: host, path: "/api/status", timeout: seconds ?? 10) else { return nil }
        return ConsolePullProgress(
            active: JSONScalarReader.bool(body, key: "pull"),
            name: JSONScalarReader.string(body, key: "pullName"),
            receivedBytes: JSONScalarReader.integer(body, key: "pullGot") ?? 0,
            totalBytes: JSONScalarReader.integer(body, key: "pullWant") ?? -1,
            paused: JSONScalarReader.bool(body, key: "pullPaused")
        )
    }

    // MARK: - Install

    /// `POST /api/install` — hand a PKG URL to the console.
    ///
    /// `url` and `iconURL` are percent-encoded exactly once (upstream issue
    /// #6): the receiver decodes once, so double encoding would break the
    /// install while no encoding breaks on spaces.
    public func push(
        host: String,
        url: String,
        name: String? = nil,
        iconURL: String? = nil
    ) async -> ConsoleReply {
        let json = Self.installRequest(url: url, name: name, iconURL: iconURL)
        guard let body = await post(host: host, path: "/api/install", json: json) else {
            return ConsoleReply(unreachable: "no reply on \(ports.map(String.init).joined(separator: "/"))")
        }
        return ConsoleReply(ok: body.contains("\"success\""), body: body, reached: true)
    }

    /// `POST /api/files/pull` — let the receiver fetch a PC file into
    /// `/data/homebrew` itself. `resume` continues a partial file.
    public func pull(
        host: String,
        url: String,
        remotePath: String,
        resume: Bool = false
    ) async -> ConsoleReply {
        let json = Self.pullRequest(url: url, remotePath: remotePath, resume: resume)
        guard let body = await post(host: host, path: "/api/files/pull", json: json) else {
            return ConsoleReply(unreachable: "no reply on \(ports.map(String.init).joined(separator: "/"))")
        }
        return ConsoleReply(
            ok: body.contains("started") || body.contains("\"ok\""),
            body: body,
            reached: true
        )
    }

    /// `POST /api/pull/pause` — pause or resume the running pull copy.
    public func setPullPaused(host: String, paused: Bool) async -> Bool {
        let json = Self.pauseRequest(paused: paused)
        guard let body = await post(host: host, path: "/api/pull/pause", json: json, timeout: 10) else {
            return false
        }
        return body.contains("\"ok\"")
    }

    /// `POST /api/pull/cancel` — stop the pull copy (partial file is kept).
    public func cancelPull(host: String) async -> Bool {
        guard let body = await post(
            host: host,
            path: "/api/pull/cancel",
            json: "{}",
            timeout: 10,
            ports: [Self.primaryPort]
        ) else { return false }
        return body.contains("\"ok\"")
    }

    /// `GET /api/files/stat` — remote file size, used to verify a copy landed
    /// byte-complete.
    public func stat(host: String, remotePath: String, timeout seconds: TimeInterval? = nil) async -> RemoteFileStatus? {
        let path = "/api/files/stat?path=" + URLEncoding.encodeQueryValue(remotePath)
        guard let body = await get(host: host, path: path, timeout: seconds ?? 10) else { return nil }
        return RemoteFileStatus(
            exists: JSONScalarReader.bool(body, key: "exists"),
            size: JSONScalarReader.integer(body, key: "size") ?? -1
        )
    }

    // MARK: - Request bodies

    /// `{"type":"direct","packages":["<url>"]}` plus optional name/icon.
    ///
    /// `url` is rewritten to http and percent-encoded exactly once; the
    /// receiver decodes once, so encoding twice would break the install
    /// (upstream issue #6).
    public static func installRequest(url: String, name: String? = nil, iconURL: String? = nil) -> String {
        let encoded = URLEncoding.encodeOnce(url.replacingOccurrences(of: "https://", with: "http://"))
        var json = "{\"type\":\"direct\",\"packages\":[\"\(encoded)\"]"
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            json += ",\"name\":\"\(JSONText.escapeForConsole(name))\""
        }
        if let iconURL, !iconURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            json += ",\"icon_url\":\"\(JSONText.escapeForConsole(URLEncoding.encodeOnce(iconURL)))\""
        }
        return json + "}"
    }

    /// `{"url":…,"path":…,"mode":"overwrite"|"resume"}`.
    public static func pullRequest(url: String, remotePath: String, resume: Bool = false) -> String {
        """
        {"url":"\(JSONText.escapeForConsole(url))","path":"\(JSONText.escapeForConsole(remotePath))",\
        "mode":"\(resume ? "resume" : "overwrite")"}
        """
    }

    /// `{"paused":1|0}`.
    public static func pauseRequest(paused: Bool) -> String {
        "{\"paused\":\(paused ? 1 : 0)}"
    }

    // MARK: - Transport

    /// GET `path` from one specific port (used by the PS4 probes).
    public func get(host: String, port: Int, path: String, timeout seconds: TimeInterval) async -> String? {
        await request(host: host, port: port, path: path, method: "GET", body: nil, timeout: seconds)
    }

    /// POST `json` to one specific port.
    public func post(
        host: String,
        port: Int,
        path: String,
        json: String,
        timeout seconds: TimeInterval
    ) async -> String? {
        await request(host: host, port: port, path: path, method: "POST", body: Data(json.utf8), timeout: seconds)
    }

    /// GET `path` from the first port that answers with a 2xx body.
    public func get(host: String, path: String, timeout seconds: TimeInterval) async -> String? {
        for port in ports {
            if let body = await request(host: host, port: port, path: path, method: "GET", body: nil, timeout: seconds) {
                return body
            }
        }
        return nil
    }

    /// POST `json` to the first port that answers 2xx.
    public func post(
        host: String,
        path: String,
        json: String,
        timeout seconds: TimeInterval = 15,
        ports: [Int]? = nil
    ) async -> String? {
        for port in ports ?? self.ports {
            if let body = await request(
                host: host,
                port: port,
                path: path,
                method: "POST",
                body: Data(json.utf8),
                timeout: seconds
            ) {
                return body
            }
        }
        return nil
    }

    private func request(
        host: String,
        port: Int,
        path: String,
        method: String,
        body: Data?,
        timeout seconds: TimeInterval
    ) async -> String? {
        guard let url = URL(string: endpoint(host: host, port: port, path: path)) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: seconds)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// `http://host:port/path`, bracketing literal IPv6 hosts.
    public func endpoint(host: String, port: Int, path: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let presented = trimmed.contains(":") && !trimmed.hasPrefix("[") ? "[\(trimmed)]" : trimmed
        return "http://\(presented):\(port)\(path)"
    }
}

public extension URLSession {
    /// Session used by `ConsoleClient`: no cache, no cookies, short connect
    /// timeout so a dead console IP fails fast.
    static let pkgSenderDefault: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpShouldUsePipelining = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()
}
