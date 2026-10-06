import Foundation

/// Outcome of parsing the `Range` header against a resource size.
///
/// Mirrors the receiver's expectations: the PS5 downloader asks for open-ended
/// ranges (`bytes=1024-`) to resume and for suffix ranges (`bytes=-4096`) to
/// read trailing metadata.
public enum HTTPByteRange: Sendable, Equatable, CustomStringConvertible {
    /// No (usable) range: answer 200 with the whole body.
    case full(size: Int64)
    /// Satisfiable range: answer 206 with `start...end` (both inclusive).
    case partial(start: Int64, end: Int64, size: Int64)
    /// Range points past the end: answer 416.
    case unsatisfiable(size: Int64)

    public var size: Int64 {
        switch self {
        case .full(let size), .unsatisfiable(let size): return size
        case .partial(_, _, let size): return size
        }
    }

    /// First byte of the payload.
    public var start: Int64 {
        switch self {
        case .full: return 0
        case .partial(let start, _, _): return start
        case .unsatisfiable: return 0
        }
    }

    /// Last byte of the payload (inclusive).
    public var end: Int64 {
        switch self {
        case .full(let size): return max(0, size - 1)
        case .partial(_, let end, _): return end
        case .unsatisfiable(let size): return max(0, size - 1)
        }
    }

    /// Bytes to send.
    public var length: Int64 {
        switch self {
        case .full(let size): return size
        case .partial(let start, let end, _): return end - start + 1
        case .unsatisfiable: return 0
        }
    }

    public var statusCode: Int {
        switch self {
        case .full: return 200
        case .partial: return 206
        case .unsatisfiable: return 416
        }
    }

    public var reason: String {
        switch self {
        case .full: return "OK"
        case .partial: return "Partial Content"
        case .unsatisfiable: return "Range Not Satisfiable"
        }
    }

    /// `Content-Range` value: `bytes start-end/size`, or `bytes */size` for 416.
    public var contentRange: String? {
        switch self {
        case .full: return nil
        case .partial(let start, let end, let size): return "bytes \(start)-\(end)/\(size)"
        case .unsatisfiable(let size): return "bytes */\(size)"
        }
    }

    public var description: String {
        switch self {
        case .full(let size): return "200 full (\(size) bytes)"
        case .partial(let start, let end, let size): return "206 \(start)-\(end)/\(size)"
        case .unsatisfiable(let size): return "416 (size \(size))"
        }
    }
}

/// Parses `Range: bytes=…` headers the way the console's downloader uses them.
public enum HTTPRangeParser {
    /// Parse a single header value.
    ///
    /// - Note: Multi-range (`bytes=0-1,3-4`) is not supported and falls back to
    ///   a full 200 response, exactly like the upstream server.
    public static func parse(header value: String?, size: Int64) -> HTTPByteRange {
        guard let value else { return .full(size: size) }
        let spec = value.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else { return .full(size: size) }
        let range = String(spec.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        guard !range.isEmpty, !range.contains(",") else { return .full(size: size) }

        let parts = range.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full(size: size) }

        // Suffix range: last N bytes.
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return .full(size: size) }
            return .partial(start: max(0, size - suffix), end: max(0, size - 1), size: size)
        }

        guard let start = Int64(parts[0]) else { return .full(size: size) }
        guard start < size else { return .unsatisfiable(size: size) }
        var end = max(0, size - 1)
        if !parts[1].isEmpty {
            guard let requested = Int64(parts[1]) else { return .full(size: size) }
            end = min(requested, max(0, size - 1))
        }
        guard end >= start else { return .unsatisfiable(size: size) }
        return .partial(start: start, end: end, size: size)
    }

    /// Parse every `Range` header of a request; the last valid one wins and an
    /// unsatisfiable one short-circuits (upstream semantics).
    public static func parse(headers values: [String], size: Int64) -> HTTPByteRange {
        var result = HTTPByteRange.full(size: size)
        for value in values {
            let parsed = parse(header: value, size: size)
            if case .unsatisfiable = parsed { return parsed }
            if case .partial = parsed { result = parsed }
        }
        return result
    }
}
