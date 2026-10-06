import Foundation

/// Minimal read-only exFAT walker.
///
/// PS5 dumps are often distributed as a raw exFAT image rather than a PKG.
/// All that is needed for the library is `sce_sys/param.json` and
/// `sce_sys/icon0.png`, so this is a targeted directory walk — no writes, no
/// journal replay, and every read is bounded.
///
/// One quirk is inherited from the upstream implementation on purpose: images
/// produced by simple dumpers lay files out contiguously but leave the FAT
/// zeroed. A zero/absent chain pointer therefore falls through to the next
/// cluster instead of ending the walk, which is what makes those images
/// readable at all.
public enum ExfatReader {
    static let endOfChain: UInt32 = 0xFFFF_FFF8

    /// Read an exFAT image on disk.
    public static func read(url: URL) -> PkgInfo? {
        guard let source = FileByteSource(url: url) else { return nil }
        return read(source, name: url.lastPathComponent)
    }

    /// Read an exFAT image from any bounded byte source.
    public static func read(_ source: any ByteSource, name: String) -> PkgInfo? {
        guard let fs = FS(source: source) else { return nil }
        guard let sce = fs.findDirectory(in: fs.rootCluster, contiguous: false, size: nil,
                                         name: "sce_sys") else { return nil }
        guard let pj = fs.findFile(in: sce.first, contiguous: sce.noFat, size: sce.size,
                                   name: "param.json") else { return nil }
        let json = fs.readFile(pj, cap: ParamJSON.maxBytes)
        guard !json.isEmpty, let meta = ParamJSON.parse(json) else { return nil }

        var icon: Data?
        if let ic = fs.findFile(in: sce.first, contiguous: sce.noFat, size: sce.size,
                                name: "icon0.png") {
            let data = fs.readFile(ic, cap: 8 * 1024 * 1024)
            if data.count >= 8, data[0] == 0x89, data[1] == 0x50 { icon = data }
        }

        let titleId = meta.titleId.isEmpty ? GameReader.titleIdFromName(name) : meta.titleId
        let title = meta.title.isEmpty
            ? (titleId.isEmpty ? (name as NSString).lastPathComponent : titleId)
            : meta.title

        var params: [PkgParam] = []
        if !titleId.isEmpty { params.append(PkgParam("TITLE_ID", titleId)) }
        if !meta.contentId.isEmpty { params.append(PkgParam("CONTENT_ID", meta.contentId)) }
        if !meta.version.isEmpty { params.append(PkgParam("VERSION", meta.version)) }

        return PkgInfo(title: title,
                       contentId: meta.contentId,
                       titleId: titleId,
                       version: meta.version,
                       platform: "PS5",
                       description: "[PS5 exfat image] \(title)",
                       packageSize: source.byteCount,
                       format: "exfat",
                       digest: "",
                       iconData: icon,
                       params: params)
    }

    // MARK: - On-image structures

    struct Node {
        var name: String
        var isDirectory: Bool
        var first: UInt32
        var size: UInt64
        /// File is stored contiguously (no FAT chain to follow).
        var noFat: Bool
    }

    struct FS {
        let source: any ByteSource
        let sectorSize: Int
        let clusterSectors: Int
        let fatBase: UInt64
        let heapBase: UInt64
        let rootCluster: UInt32

        var clusterBytes: Int { sectorSize * clusterSectors }

        init?(source: any ByteSource) {
            guard let vbr = source.read(at: 0, count: 512) else { return nil }
            let r = ByteReader(vbr)
            guard r.fixedString(at: 3, length: 8) == "EXFAT   " else { return nil }
            guard let partOffset = r.u64le(at: 0x40),
                  let fatOffset = r.u32le(at: 0x50),
                  let heapOffset = r.u32le(at: 0x58),
                  let root = r.u32le(at: 0x60),
                  let sectorShift = r.u8(at: 0x6C),
                  let clusterShift = r.u8(at: 0x6D) else { return nil }
            // Sector size 512...4096; cluster size must stay sane or every
            // cluster address below would be meaningless.
            guard sectorShift >= 9, sectorShift <= 12, clusterShift <= 25 else { return nil }

            self.source = source
            self.sectorSize = 1 << sectorShift
            self.clusterSectors = 1 << clusterShift
            self.rootCluster = root

            let sector = UInt64(self.sectorSize)
            guard let fat = Self.mul(partOffset + UInt64(fatOffset), sector),
                  let heap = Self.mul(partOffset + UInt64(heapOffset), sector) else {
                return nil
            }
            self.fatBase = fat
            self.heapBase = heap
        }

        /// Byte offset of a cluster, or `UInt64.max` when it cannot exist.
        func clusterAddress(_ cluster: UInt32) -> UInt64 {
            guard cluster >= 2 else { return UInt64.max }
            guard let span = Self.mul(UInt64(cluster - 2), UInt64(clusterBytes)) else {
                return UInt64.max
            }
            let (sum, overflow) = heapBase.addingReportingOverflow(span)
            return overflow ? UInt64.max : sum
        }

        func fatNext(_ cluster: UInt32) -> UInt32 {
            guard let delta = Self.mul(UInt64(cluster), 4) else { return endOfChain }
            let (at, overflow) = fatBase.addingReportingOverflow(delta)
            guard !overflow else { return endOfChain }
            guard let raw = source.read(at: at, count: 4),
                  let next = ByteReader(raw).u32le(at: 0) else { return endOfChain }
            return next
        }

        /// Zeroed-FAT images: step to the next cluster instead of stopping.
        private static func linearNext(_ cluster: UInt32) -> UInt32 {
            cluster == UInt32.max ? cluster : cluster + 1
        }

        /// Read a byte range, tolerating a short read at the end of the image.
        func read(at offset: UInt64, count: Int) -> Data {
            guard offset < UInt64(Int.max), count >= 0 else { return Data() }
            guard count > 0 else { return Data() }
            guard offset <= UInt64(source.byteCount) else { return Data() }
            let available = Int(UInt64(source.byteCount) - offset)
            let take = min(count, available)
            return source.read(at: offset, count: take) ?? Data()
        }

        /// Directory bytes, following the cluster chain (or running
        /// contiguously) until `maxBytes` or the end of the chain.
        func readDirectory(first: UInt32, contiguous: Bool, size: UInt64?,
                           maxBytes: Int = 1 << 24) -> Data {
            let want = size.map { Int(min($0, UInt64(maxBytes))) } ?? maxBytes
            var out = Data()
            out.reserveCapacity(min(want, 1 << 20))
            var cluster = first
            var hops = 0
            while out.count < want, hops < 4096 {
                hops += 1
                let address = clusterAddress(cluster)
                guard address < UInt64(source.byteCount) else { break }
                let take = min(clusterBytes, want - out.count)
                let chunk = read(at: address, count: take)
                if chunk.isEmpty { break }
                out.append(chunk)
                if contiguous { break }
                let next = fatNext(cluster)
                if next >= endOfChain { break }
                // Zeroed-FAT images: fall through to the next cluster.
                cluster = next < 2 ? Self.linearNext(cluster) : next
            }
            return out
        }

        /// Parse a directory blob into entries.
        func parseDirectory(_ raw: Data, want: String? = nil) -> [Node] {
            var nodes: [Node] = []
            var attrs: UInt16 = 0
            var first: UInt32 = 0
            var size: UInt64 = 0
            var noFat = false
            var parts: [String] = []
            var pending = false
            var nameCount = 1

            let bytes = [UInt8](raw)
            let r = ByteReader(bytes)
            var i = 0
            while i + 32 <= bytes.count {
                let type = bytes[i]
                if type == 0x00 { break }              // end of directory
                if type == 0x85 {
                    attrs = r.u16le(at: i + 4) ?? 0
                    nameCount = max(1, Int(bytes[i + 1]))
                    parts = []
                    pending = true
                } else if type == 0xC0, pending {
                    // Stream extension: byte 1 is GeneralSecondaryFlags and
                    // its bit 1 is NoFatChain. (Reading a u16 at +2 instead
                    // picks up NameLength and never matches — an upstream
                    // port has this wrong.)
                    let flags = r.u8(at: i + 1) ?? 0
                    noFat = (flags & 0x02) != 0
                    first = r.u32le(at: i + 20) ?? 0
                    size = r.u64le(at: i + 24) ?? 0
                } else if type == 0xC1, pending {
                    var chars: [UInt16] = []
                    for c in 0..<15 {
                        guard let v = r.u16le(at: i + 2 + c * 2), v != 0 else { break }
                        chars.append(v)
                    }
                    if !chars.isEmpty {
                        parts.append(String(utf16CodeUnits: chars, count: chars.count))
                    }
                    if parts.count >= nameCount - 1 {
                        let name = parts.joined()
                        nodes.append(Node(name: name,
                                          isDirectory: (attrs & 0x10) != 0,
                                          first: first, size: size, noFat: noFat))
                        pending = false
                        if let want, want.caseInsensitiveCompare(name) == .orderedSame {
                            return nodes
                        }
                    }
                }
                i += 32
                if nodes.count > 20_000 { break }
            }
            return nodes
        }

        func findDirectory(in cluster: UInt32, contiguous: Bool, size: UInt64?,
                           name: String) -> Node? {
            let raw = readDirectory(first: cluster, contiguous: contiguous, size: size)
            return parseDirectory(raw, want: name).first {
                $0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
        }

        func findFile(in cluster: UInt32, contiguous: Bool, size: UInt64?,
                      name: String) -> Node? {
            let raw = readDirectory(first: cluster, contiguous: contiguous, size: size)
            return parseDirectory(raw, want: name).first {
                !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
        }

        /// Read a file's bytes, capped. Empty when the chain is unreadable.
        func readFile(_ node: Node, cap: Int) -> Data {
            let want = Int(min(node.size, UInt64(cap)))
            guard want > 0, node.first >= 2 else { return Data() }
            if node.noFat {
                let address = clusterAddress(node.first)
                guard address < UInt64(source.byteCount) else { return Data() }
                return read(at: address, count: want)
            }
            var out = Data()
            out.reserveCapacity(want)
            var cluster = node.first
            var hops = 0
            while out.count < want, hops < 8192 {
                hops += 1
                let address = clusterAddress(cluster)
                guard address < UInt64(source.byteCount) else { break }
                let take = min(clusterBytes, want - out.count)
                let chunk = read(at: address, count: take)
                if chunk.count != take { break }
                out.append(chunk)
                if out.count >= want { break }
                let next = fatNext(cluster)
                if next >= endOfChain { break }
                cluster = next < 2 ? Self.linearNext(cluster) : next
            }
            return out
        }

        /// Overflow-checked multiplication; nil on overflow.
        private static func mul(_ a: UInt64, _ b: UInt64) -> UInt64? {
            let (v, overflow) = a.multipliedReportingOverflow(by: b)
            return overflow ? nil : v
        }
    }
}
