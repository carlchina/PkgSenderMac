import Foundation

/// The CNT container shared by PS4 and PS5 packages.
///
/// PS4 packages *are* a CNT (`\x7FCNT` at offset 0); PS5 packages wrap one in
/// an FIH header (`\x7FFIH`) whose byte 0x58 holds the CNT offset. Everything
/// after that point is the same layout: a header with the content id, an entry
/// table, a name table and the entry payloads — so one walker serves both.
struct CntImage {
    struct Entry {
        var id: UInt32
        var nameOffset: UInt32
        var flags: UInt32
        var dataOffset: UInt32
        var dataSize: UInt32
        var name: String

        /// Bit 31 marks a directory / non-data entry.
        var isDirectory: Bool { (flags & 0x8000_0000) != 0 }
    }

    static let fihMagic: [UInt8] = [0x7F, 0x46, 0x49, 0x48]   // \x7FFIH
    static let cntMagic: [UInt8] = [0x7F, 0x43, 0x4E, 0x54]   // \x7FCNT
    /// Legacy PS4 PKG magic (`\x7FPKG`). Same container role as `\x7FCNT` but
    /// a different header: content id at 0x30 (not 0x40) and no usable entry
    /// table at the standard offsets (param.sfo lives inside the PFS image),
    /// so we read header content id + digest and send it best-effort.
    static let pkgMagic: [UInt8] = [0x7F, 0x50, 0x4B, 0x47]   // \x7FPKG

    static let headerSize = 0x5A0
    /// PKG header digest lives here: 32 bytes, rendered as uppercase hex.
    static let digestOffset = 0xFE0
    static let digestSize = 32

    static let nameTableId: UInt32 = 0x0200
    static let paramSfoId: UInt32 = 0x1000
    static let paramJsonId: UInt32 = 0x2000
    static let iconId: UInt32 = 0x1200

    let base: UInt64
    let contentId: String
    let digest: String
    let isDebug: Bool
    let isMeta: Bool
    /// True for the legacy PS4 `\x7FPKG` variant, which has no resolvable
    /// entry table; callers fall back to the header content id + digest.
    let isPKG: Bool
    let entries: [Entry]
    private let source: any ByteSource

    private init(base: UInt64, contentId: String, digest: String, isDebug: Bool,
                 isMeta: Bool, isPKG: Bool, entries: [Entry], source: any ByteSource) {
        self.base = base
        self.contentId = contentId
        self.digest = digest
        self.isDebug = isDebug
        self.isMeta = isMeta
        self.isPKG = isPKG
        self.entries = entries
        self.source = source
    }

    /// Open a CNT, transparently stepping through an FIH wrapper. Also
    /// accepts the legacy PS4 `\x7FPKG` magic, where only the header content
    /// id + digest are reliable (the entry table is not at the standard
    /// offsets and param.sfo sits inside the PFS image).
    static func open(_ source: any ByteSource) -> CntImage? {
        guard source.byteCount >= headerSize,
              let magic = source.read(at: 0, count: 4) else { return nil }
        let head = [UInt8](magic)

        var cntBase: UInt64 = 0
        var isDebug = false
        var isMeta = false
        var isPKG = false

        if head == fihMagic {
            guard let fih = source.read(at: 0, count: 0x60) else { return nil }
            let r = ByteReader(fih)
            // Byte 5 is the signature flag: 0x80 = official (signed).
            isDebug = (r.u8(at: 0x05) ?? 0) != 0x80
            guard let embedded = r.u64le(at: 0x58), embedded > 0 else { return nil }
            // The CNT must fit: refuse offsets that point past the file.
            guard embedded <= UInt64(source.byteCount - Int64(headerSize)) else { return nil }
            cntBase = embedded
        } else if head == cntMagic || head == pkgMagic {
            isPKG = (head == pkgMagic)
            isDebug = true
            isMeta = true
        } else {
            return nil
        }

        // Legacy PS4 PKG keeps the content id at 0x30; CNT/FIH at 0x40.
        let cidOffset = isPKG ? 0x30 : 0x40
        let expectedMagic = isPKG ? pkgMagic : cntMagic

        guard let header = source.read(at: cntBase, count: headerSize) else { return nil }
        let hr = ByteReader(header)
        guard hr.bytes(at: 0, count: 4) == expectedMagic else { return nil }

        // Entry table: CNT/FIH always expose one; legacy PKG does not, so we
        // skip entry parsing there and rely on the header content id + digest.
        var raw: [RawEntry] = []
        if !isPKG {
            guard let count = hr.u32be(at: 0x10),
                  let tableOffset = hr.u32be(at: 0x18),
                  count > 0, count <= 0x1_0000 else { return nil }
            guard let table = source.read(at: cntBase + UInt64(tableOffset),
                                          count: Int(count) * 0x20) else { return nil }
            let tr = ByteReader(table)
            for i in 0..<Int(count) {
                let o = i * 0x20
                guard let id = tr.u32be(at: o),
                      let nameOffset = tr.u32be(at: o + 4),
                      let flags = tr.u32be(at: o + 8),
                      let dataOffset = tr.u32be(at: o + 0x10),
                      let dataSize = tr.u32be(at: o + 0x14) else { break }
                raw.append(RawEntry(id: id, nameOffset: nameOffset, flags: flags,
                                    dataOffset: dataOffset, dataSize: dataSize))
            }
        }
        // NB: an empty entry table is valid for legacy PKG — do not fail open.

        let names = isPKG ? [:] : readNameTable(source, base: cntBase, entries: raw)
        var entries: [Entry] = []
        entries.reserveCapacity(raw.count)
        for e in raw {
            entries.append(Entry(id: e.id, nameOffset: e.nameOffset, flags: e.flags,
                                 dataOffset: e.dataOffset, dataSize: e.dataSize,
                                 name: names[e.nameOffset] ?? ""))
        }

        return CntImage(base: cntBase,
                        contentId: hr.fixedString(at: Int(cidOffset), length: 0x30)?
                            .trimmingCharacters(in: .whitespaces) ?? "",
                        digest: readDigest(source, base: cntBase),
                        isDebug: isDebug,
                        isMeta: isMeta,
                        isPKG: isPKG,
                        entries: entries,
                        source: source)
    }

    /// Entry lookup: by id first, then by name (case-insensitive).
    /// Directory entries are skipped — they carry no payload.
    func find(id: UInt32, name: String) -> Entry? {
        if let hit = entries.first(where: { $0.id == id && !$0.isDirectory }) { return hit }
        return entries.first {
            !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Read an entry payload, refusing anything larger than `cap`.
    /// Returns empty data (not nil) for entries that cannot be read.
    func readEntry(_ entry: Entry, cap: Int) -> Data {
        guard !entry.isDirectory, entry.dataSize > 0, entry.dataSize <= cap else {
            return Data()
        }
        return source.read(at: base + UInt64(entry.dataOffset),
                           count: Int(entry.dataSize)) ?? Data()
    }

    /// Cover search: the declared icon entry first, then the icon variants.
    ///
    /// There is deliberately no fuzzy `*icon*.png` fallback: patch and DLC
    /// packages often bundle a generic or unrelated icon, and that used to
    /// land on the wrong card in family view. No exact icon -> no cover,
    /// and the UI shows a placeholder tile instead.
    func findIcon(cap: Int = 8 * 1024 * 1024) -> Data? {
        func looksLikePNG(_ d: Data) -> Bool {
            d.count >= 8 && d[0] == 0x89 && d[1] == 0x50
        }
        for entry in entries where entry.id == Self.iconId && !entry.isDirectory {
            let d = readEntry(entry, cap: cap)
            if looksLikePNG(d) { return d }
        }
        for entry in entries where entry.id > Self.iconId && entry.id <= Self.iconId + 0x20
            && !entry.isDirectory {
            let d = readEntry(entry, cap: cap)
            if looksLikePNG(d) { return d }
        }
        return nil
    }

    /// The name table: entry 0x200, a blob of NUL-separated ASCII names
    /// addressed by byte offset.
    private static func readNameTable(
        _ source: any ByteSource,
        base: UInt64,
        entries: [RawEntry]
    ) -> [UInt32: String] {
        guard let nt = entries.first(where: { $0.id == nameTableId }),
              !nt.isDirFlag, nt.dataSize > 0, nt.dataSize <= 4 * 1024 * 1024,
              let blob = source.read(at: base + UInt64(nt.dataOffset),
                                     count: Int(nt.dataSize)) else { return [:] }
        let raw = [UInt8](blob)
        var names: [UInt32: String] = [:]
        var start = 0
        for i in 0...raw.count {
            if i == raw.count || raw[i] == 0 {
                if i > start {
                    names[UInt32(start)] =
                        String(decoding: raw[start..<i], as: UTF8.self)
                }
                start = i + 1
            }
        }
        return names
    }

    private static func readDigest(_ source: any ByteSource, base: UInt64) -> String {
        guard let d = source.read(at: base + UInt64(digestOffset), count: digestSize) else {
            return ""
        }
        return [UInt8](d).map { String(format: "%02X", $0) }.joined()
    }
}

/// Entry as decoded from the table, before names are resolved.
private struct RawEntry {
    var id: UInt32
    var nameOffset: UInt32
    var flags: UInt32
    var dataOffset: UInt32
    var dataSize: UInt32

    /// Bit 31 marks a directory / non-data entry.
    var isDirFlag: Bool { (flags & 0x8000_0000) != 0 }
}
