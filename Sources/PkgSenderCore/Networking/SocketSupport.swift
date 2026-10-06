import Darwin
import Foundation

/// BSD socket primitives used by the discovery sweep, the beacon listener and
/// the range server.
///
/// Everything here is synchronous and blocking: callers run it on a GCD worker
/// (see `runBlocking`) so it never parks a Swift concurrency thread.
enum SocketSupport {
    /// macOS has no `MSG_NOSIGNAL`; without this a reset peer kills the host
    /// process with SIGPIPE instead of failing `send`.
    static func disableSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setReuseAddress(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Accepted sockets inherit the listener's non-blocking flag on Darwin,
    /// which would turn every `recv` into EAGAIN; connections are served
    /// blocking (with `SO_RCVTIMEO`) instead.
    static func setBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    }

    /// Read/write timeout so a stalled console cannot pin a worker forever.
    static func setTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func sockaddrIn(_ address: IPv4Address = .zero, port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = address.bigEndianRawValue
        return addr
    }

    /// Sender address of the last datagram, or nil when it is not IPv4.
    static func senderAddress(of storage: sockaddr_storage) -> IPv4Address? {
        guard Int32(storage.ss_family) == AF_INET else { return nil }
        var mutable = storage
        return withUnsafePointer(to: &mutable) { pointer -> IPv4Address? in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inbound in
                IPv4Address(rawValue: UInt32(bigEndian: inbound.pointee.sin_addr.s_addr))
            }
        }
    }

    /// Writes every byte or returns false (peer gone / timeout).
    static func sendAll(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let written = send(fd, bytes.advanced(by: sent), count - sent, 0)
            if written > 0 {
                sent += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }

    static func sendAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        data.isEmpty ? true : data.withUnsafeBytes { sendAll(fd, $0.baseAddress!, $0.count) }
    }

    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.isEmpty ? true : data.withUnsafeBytes { sendAll(fd, $0.baseAddress!, $0.count) }
    }

    static func sendAll(_ fd: Int32, _ text: String) -> Bool {
        sendAll(fd, Array(text.utf8))
    }

    /// Single `recv`; returns 0 on orderly close and -1 on error/timeout.
    static func receive(_ fd: Int32, into buffer: UnsafeMutableRawPointer, length: Int) -> Int {
        let read = recv(fd, buffer, length, 0)
        if read < 0, errno == EINTR { return receive(fd, into: buffer, length: length) }
        return read
    }

    /// Connects to `address:port` within the timeout; returns the socket or -1.
    static func connect(to address: IPv4Address, port: Int, timeoutMs: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }
        disableSIGPIPE(fd)
        setNonBlocking(fd)

        var target = sockaddrIn(address, port: port)
        let started = withUnsafePointer(to: &target) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return fd }

        guard errno == EINPROGRESS else {
            close(fd)
            return -1
        }
        var status = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&status, 1, Int32(timeoutMs)) == 1 else {
            close(fd)
            return -1
        }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        guard error == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    /// True when a TCP connect to `address:port` completes within the timeout.
    static func canConnect(to address: IPv4Address, port: Int, timeoutMs: Int) -> Bool {
        let fd = connect(to: address, port: port, timeoutMs: timeoutMs)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Waits up to `timeoutMs` for an inbound connection; -1 when none arrives.
    static func accept(fd: Int32, timeoutMs: Int) -> Int32 {
        var pollfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollfd, 1, Int32(timeoutMs)) == 1 else { return -1 }
        return Darwin.accept(fd, nil, nil)
    }

    /// Runs blocking work on a GCD worker so cooperative threads stay free.
    static func runBlocking<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: body())
            }
        }
    }

    static func describeLastError(_ context: String) -> String {
        "\(context): \(String(cString: strerror(errno))) (\(errno))"
    }
}
