import Foundation

/// Random access to a bounded byte stream.
///
/// Parsing a package only ever reads headers, entry tables and the small
/// metadata files inside, so a seekable source (rather than a full read)
/// keeps memory flat for multi-GB PKGs and exFAT disk images. `Sendable`
/// because scanning runs on a background thread.
public protocol ByteSource: Sendable {
    /// Total size in bytes.
    var byteCount: Int64 { get }
    /// Exactly `count` bytes at `offset`, or nil when the range leaves the
    /// stream or the read fails. Never returns a short buffer.
    func read(at offset: UInt64, count: Int) -> Data?
}

/// A file opened read-only and read with `pread`.
///
/// `pread` is used instead of a seek+read pair so concurrent scans of the
/// same volume cannot interleave offsets on one descriptor. The descriptor
/// is closed on deinit; immutable state makes the class safe to share.
public final class FileByteSource: ByteSource, @unchecked Sendable {
    public let url: URL
    public let byteCount: Int64
    private let descriptor: Int32

    public init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return nil
        }
        // Anything that is not a regular file (FIFO, socket, directory)
        // cannot satisfy a random-access read; reject it up front.
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        self.url = url
        self.descriptor = fd
        self.byteCount = Int64(st.st_size)
    }

    deinit { close(descriptor) }

    public func read(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard offset < UInt64(Int.max), offset + UInt64(count) <= UInt64(byteCount) else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                pread(descriptor, raw.baseAddress, count - filled, off_t(offset) + off_t(filled))
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }   // truncated: refuse to return short data
            filled += n
        }
        return Data(buffer)
    }
}

/// An in-memory source: used by the tests and for entries already read.
public struct MemoryByteSource: ByteSource {
    public let data: Data

    public init(_ data: Data) { self.data = data }

    public var byteCount: Int64 { Int64(data.count) }

    public func read(at offset: UInt64, count: Int) -> Data? {
        guard count >= 0, let o = Int(exactly: offset), o >= 0,
              count <= data.count - o else { return nil }
        if count == 0 { return Data() }
        return Data(data[o..<(o + count)])
    }
}
