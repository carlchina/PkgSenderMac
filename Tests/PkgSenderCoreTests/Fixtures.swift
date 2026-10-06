import Foundation
@testable import PkgSenderCore

/// Synthetic packages and temp directories for the parsing / scan tests.
///
/// Real PKGs are tens of gigabytes and cannot live in a repository, so the
/// tests build the exact byte layouts the readers expect: a `param.sfo`
/// index table, a CNT header + entry table, and an FIH wrapper. That keeps
/// the byte-level assumptions (offsets, endianness, the digest slot) under
/// test instead of merely exercised by whatever files happen to be on disk.
enum Fixtures {

    // MARK: - Temp files

    static func makeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PkgSenderTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Byte helpers

    static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }

    static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    static func be32(_ v: UInt32) -> Data {
        var x = v.bigEndian
        return Data(bytes: &x, count: 4)
    }

    static func le64(_ v: UInt64) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 8)
    }

    static func cString(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        return d
    }

    // MARK: - param.sfo

    /// Build a PSF blob holding UTF-8 string entries.
    static func sfo(_ entries: [(String, String)]) -> Data {
        var keys = Data()
        var values = Data()
        var keyOffsets: [UInt16] = []
        var valueOffsets: [UInt32] = []
        var lengths: [UInt32] = []

        for (key, value) in entries {
            keyOffsets.append(UInt16(keys.count))
            keys.append(cString(key))
            valueOffsets.append(UInt32(values.count))
            let raw = Data(value.utf8)
            // Length counts the NUL terminator, as the real format does.
            lengths.append(UInt32(raw.count + 1))
            values.append(raw)
            values.append(0)
        }

        let keyTable = UInt32(0x14 + entries.count * 0x10)
        let dataTable = keyTable + UInt32(keys.count)

        var out = Data()
        out.append(Data([0x00, 0x50, 0x53, 0x46]))         // \0PSF
        out.append(le32(0x0000_0101))                       // version
        out.append(le32(keyTable))
        out.append(le32(dataTable))
        out.append(le32(UInt32(entries.count)))
        for i in 0..<entries.count {
            out.append(le16(keyOffsets[i]))
            out.append(le16(0x0204))                        // UTF-8, NUL padded
            out.append(le32(lengths[i]))                    // used length
            out.append(le32(lengths[i]))                    // allocated length
            out.append(le32(valueOffsets[i]))
        }
        out.append(keys)
        out.append(values)
        return out
    }

    // MARK: - Containers

    struct Entry {
        var id: UInt32
        var name: String
        var data: Data

        init(id: UInt32, name: String, data: Data) {
            self.id = id
            self.name = name
            self.data = data
        }
    }

    /// Minimal PNG header — the readers only check the magic, never decode.
    static var pngIcon: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
              0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
    }

    /// Build a CNT container: header, entry table, name table, payloads.
    /// The digest is written at CNT+0xFE0 and the blob padded to 0x1000 so
    /// that slot always exists, exactly as in a real package.
    static func cnt(contentId: String, entries: [Entry], digest: Data = Data()) -> Data {
        let headerSize = 0x5A0

        var names = Data()
        var nameOffsets: [UInt32] = []
        for entry in entries {
            nameOffsets.append(UInt32(names.count))
            names.append(cString(entry.name))
        }
        // Trailing NUL: offset -> empty name for the name-table entry itself.
        let emptyNameOffset = UInt32(names.count)
        names.append(0)

        let tableBytes = (entries.count + 1) * 0x20
        var body = Data(count: tableBytes)
        let nameTableOffset = UInt32(headerSize + body.count)
        body.append(names)
        var payloadOffsets: [UInt32] = [nameTableOffset]
        for entry in entries {
            payloadOffsets.append(UInt32(headerSize + body.count))
            body.append(entry.data)
        }

        var table = Data()
        func row(_ id: UInt32, _ nameOffset: UInt32, _ offset: UInt32, _ size: UInt32) {
            table.append(be32(id))
            table.append(be32(nameOffset))
            table.append(be32(0))           // flags: bit 31 = directory
            table.append(be32(0))
            table.append(be32(offset))
            table.append(be32(size))
            table.append(be32(0))
            table.append(be32(0))
        }
        row(0x0200, emptyNameOffset, nameTableOffset, UInt32(names.count))
        for (i, entry) in entries.enumerated() {
            row(entry.id, nameOffsets[i], payloadOffsets[i + 1], UInt32(entry.data.count))
        }
        body.replaceSubrange(0..<tableBytes, with: table)

        var header = Data(count: headerSize)
        header.replaceSubrange(0..<4, with: Data([0x7F, 0x43, 0x4E, 0x54]))
        header.replaceSubrange(0x10..<0x14, with: be32(UInt32(entries.count + 1)))
        header.replaceSubrange(0x18..<0x1C, with: be32(UInt32(headerSize)))
        var cid = Data(contentId.utf8)
        if cid.count > 0x30 { cid = cid.prefix(0x30) }
        header.replaceSubrange(0x40..<(0x40 + cid.count), with: cid)

        var blob = header
        blob.append(body)
        if blob.count < 0x1000 {
            blob.append(Data(count: 0x1000 - blob.count))
        }
        var digestBytes = digest
        if digestBytes.count < 32 {
            digestBytes.append(Data(count: 32 - digestBytes.count))
        }
        blob.replaceSubrange(0xFE0..<(0xFE0 + 32), with: digestBytes.prefix(32))
        return blob
    }

    /// Wrap a CNT in an FIH header (`\x7FFIH`), the PS5 retail layout.
    /// Byte 0x58 holds the CNT offset; byte 5 marks the signature (0x80 =
    /// official). The FIH is 0x1000 bytes, so the CNT starts there.
    static func fih(cnt: Data, official: Bool = true) -> Data {
        var header = Data(count: 0x1000)
        header.replaceSubrange(0..<4, with: Data([0x7F, 0x46, 0x49, 0x48]))
        header[0x05] = official ? 0x80 : 0x00
        var offset = UInt64(0x1000).littleEndian
        header.replaceSubrange(0x58..<0x60, with: Data(bytes: &offset, count: 8))
        header.append(cnt)
        return header
    }

    // MARK: - Ready-made packages

    static func ps4Pkg(title: String, contentId: String, titleId: String,
                       category: String = "gd", version: String = "1.00",
                       icon: Data? = nil, digest: Data = Data()) -> Data {
        let entries: [(String, String)] = [
            ("TITLE", title),
            ("CONTENT_ID", contentId),
            ("TITLE_ID", titleId),
            ("CATEGORY", category),
            ("APP_VER", version),
            ("VERSION", version),
        ]
        let sfo = Fixtures.sfo(entries)
        var items = [Entry(id: 0x1000, name: "param.sfo", data: sfo)]
        if let icon { items.append(Entry(id: 0x1200, name: "icon0.png", data: icon)) }
        return cnt(contentId: contentId, entries: items, digest: digest)
    }

    static func ps5Pkg(contentId: String, title: String, titleId: String,
                       version: String = "1.00", icon: Data? = nil,
                       digest: Data = Data(), official: Bool = true) -> Data {
        let json = """
        {
          "titleId": "\(titleId)",
          "contentId": "\(contentId)",
          "contentVersion": "\(version)",
          "localizedParameters": {
            "defaultLanguage": "en-US",
            "en-US": { "titleName": "\(title)" }
          }
        }
        """
        var items = [Entry(id: 0x2000, name: "param.json",
                           data: Data(json.utf8))]
        if let icon { items.append(Entry(id: 0x1200, name: "icon0.png", data: icon)) }
        return fih(cnt: cnt(contentId: contentId, entries: items, digest: digest),
                   official: official)
    }

    // MARK: - exFAT image

    /// Minimal exFAT image: 512-byte sectors, one sector per cluster.
    ///
    ///   sector 0  VBR
    ///   sector 1  FAT (root marked end-of-chain)
    ///   sector 2  unused
    ///   cluster 2 (sector 3)  root directory -> "sce_sys"
    ///   cluster 3 (sector 4)  sce_sys        -> param.json, icon0.png
    ///   cluster 4 (sector 5)  param.json
    ///   cluster 5 (sector 6)  icon0.png
    ///
    /// Files are flagged NoFatChain and stored contiguously, which is what
    /// the dumper-built images this reader targets look like.
    static func exfat(paramJSON: Data, icon: Data? = nil) -> Data {
        let sector = 512
        var image = Data(count: sector * 7)

        // Boot sector.
        image.replaceSubrange(3..<11, with: Data("EXFAT   ".utf8))
        image.replaceSubrange(0x40..<0x48, with: le64(0))    // partition offset
        image.replaceSubrange(0x50..<0x54, with: le32(1))    // FAT offset (sector)
        image.replaceSubrange(0x58..<0x5C, with: le32(3))    // heap offset (sector)
        image.replaceSubrange(0x60..<0x64, with: le32(2))    // root cluster
        image[0x6C] = 9                                       // 512-byte sectors
        image[0x6D] = 0                                       // 1 sector per cluster
        image[510] = 0x55
        image[511] = 0xAA

        // FAT: every cluster used here is a single-cluster chain.
        for cluster in 2...5 {
            let at = sector + cluster * 4
            image.replaceSubrange(at..<(at + 4), with: le32(0xFFFF_FFF8))
        }

        /// One directory entry set (0x85 + 0xC0 + one 0xC1 name record).
        func entry(name: String, isDirectory: Bool, firstCluster: UInt32,
                   size: Int) -> Data {
            var out = Data(count: 32 * 3)
            out[0] = 0x85
            out[1] = 2                                   // secondary count
            out[4] = isDirectory ? 0x10 : 0x20           // file attributes
            out[5] = 0x00
            out[32] = 0xC0
            out[33] = 0x02                               // NoFatChain
            out[35] = UInt8(name.utf16.count)            // name length
            var first = firstCluster.littleEndian
            out.replaceSubrange(32 + 20..<32 + 24, with: Data(bytes: &first, count: 4))
            var length = UInt64(size).littleEndian
            out.replaceSubrange(32 + 24..<32 + 32, with: Data(bytes: &length, count: 8))
            out[64] = 0xC1
            var offset = 66
            for unit in name.utf16 {
                var u = unit.littleEndian
                out.replaceSubrange(offset..<(offset + 2), with: Data(bytes: &u, count: 2))
                offset += 2
            }
            return out
        }

        func writeDirectory(_ records: [Data], at offset: Int) {
            var cursor = offset
            for record in records {
                image.replaceSubrange(cursor..<(cursor + record.count), with: record)
                cursor += record.count
            }
            // 0x00 terminates the directory.
            image.replaceSubrange(cursor..<(cursor + 32), with: Data(count: 32))
        }

        writeDirectory([entry(name: "sce_sys", isDirectory: true, firstCluster: 3,
                              size: sector)],
                       at: 3 * sector)

        var sceEntries = [entry(name: "param.json", isDirectory: false,
                                firstCluster: 4, size: paramJSON.count)]
        if let icon {
            sceEntries.append(entry(name: "icon0.png", isDirectory: false,
                                    firstCluster: 5, size: icon.count))
        }
        writeDirectory(sceEntries, at: 4 * sector)

        image.replaceSubrange(5 * sector..<(5 * sector + min(paramJSON.count, sector)),
                              with: paramJSON.prefix(sector))
        if let icon {
            image.replaceSubrange(6 * sector..<(6 * sector + min(icon.count, sector)),
                                  with: icon.prefix(sector))
        }
        return image
    }

    /// A dumped PS5 app folder: `sce_sys/param.json` (+ optional icon).
    @discardableResult
    static func gameFolder(_ root: URL, name: String, title: String, titleId: String,
                           withIcon: Bool = true) -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let sce = folder.appendingPathComponent("sce_sys", isDirectory: true)
        try? FileManager.default.createDirectory(at: sce, withIntermediateDirectories: true)
        let json = """
        {
          "titleId": "\(titleId)",
          "contentId": "EP9000-\(titleId)_00-0000000000000000",
          "contentVersion": "1.00",
          "localizedParameters": { "defaultLanguage": "en-US",
                                   "en-US": { "titleName": "\(title)" } }
        }
        """
        write(Data(json.utf8), to: sce.appendingPathComponent("param.json"))
        if withIcon { write(pngIcon, to: sce.appendingPathComponent("icon0.png")) }
        return folder
    }
}
