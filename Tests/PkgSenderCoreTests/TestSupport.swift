import Darwin
import Foundation

/// Raw HTTP/1.1 client used to exercise `RangeHTTPServer` end to end.
enum TestSupport {
    /// A port nothing is listening on (bind to 0, read it back, release).
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return 19898 }
        defer { close(fd) }
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian // 127.0.0.1
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 19898 }
        var resolved = address
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return 19898 }
        return Int(UInt16(bigEndian: resolved.sin_port))
    }

    /// Waits until something accepts connections on `127.0.0.1:port`.
    @discardableResult
    static func waitForServer(port: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if fd >= 0 {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_port = UInt16(port).bigEndian
                address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
                var timeoutValue = timeval(tv_sec: 1, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                close(fd)
                if connected == 0 { return true }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    static func tempFile(contents: Data, name: String = "\(UUID().uuidString).bin") -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        try? contents.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Sends `raw` and returns the response head plus body (per Content-Length).
    static func exchange(port: Int, _ raw: String, timeoutSeconds: Int = 3) -> (head: String, body: Data)? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var bytes = Array(raw.utf8)
        guard bytes.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == bytes.count else { return nil }

        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)

        func readSome() -> Int {
            buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        }

        // Head.
        while true {
            let read = readSome()
            if read <= 0 { break }
            received.append(contentsOf: buffer[0..<read])
            if received.count >= 4 {
                for index in 0...(received.count - 4)
                where received[index] == 0x0D && received[index + 1] == 0x0A
                    && received[index + 2] == 0x0D && received[index + 3] == 0x0A {
                    let head = String(decoding: received[0...index + 3], as: UTF8.self)
                    var body = Data(received[(index + 4)...])
                    let length = contentLength(head)
                    while body.count < length {
                        let extra = readSome()
                        if extra <= 0 { break }
                        body.append(contentsOf: buffer[0..<extra])
                    }
                    return (head, body)
                }
            }
            if received.count > 65536 { break }
        }
        return nil
    }

    /// Sends `raw` and reads everything until the peer closes (keep-alive
    /// pipelines: two responses in one stream).
    static func drain(port: Int, _ raw: String, timeoutSeconds: Int = 3) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "" }

        var bytes = Array(raw.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let read = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if read <= 0 { break }
            collected.append(contentsOf: buffer[0..<read])
            if collected.count > 1_000_000 { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value) ?? 0
        }
        return 0
    }

    static func status(_ head: String) -> Int? {
        guard let line = head.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        return parts.count > 1 ? Int(parts[1]) : nil
    }

    static func header(_ name: String, in head: String) -> String? {
        for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix(name.lowercased() + ":") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
