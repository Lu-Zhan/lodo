import Foundation

/// 只读拼音词库,内存映射,不整份读进内存(键盘扩展的内存预算很紧)。
///
/// 文件格式(小端,由 `ios/Tools/build_ime_dict.py` 生成,两边改一处要同步改另一处):
///
///     "LDIM" | version u32 | syllableCount u32 | syllableBlobLength u32
///     syllable blob(ASCII,\0 分隔)| 补齐到 4 字节
///     entryCount u32 | entryBlobLength u32 | offsets u32 × entryCount
///     entry blob:每条 = n u8 | 音节编号 u16 × n | cost u16 | 字节数 u8 | UTF-8
///
/// 条目按(音节编号序列, cost)排序,所以同一个前缀的条目连在一起,
/// 而且其中音节数恰好等于前缀长度的那些排在最前、按 cost 从低到高。
/// cost 是 -ln(p) × 100。
public final class Lexicon: @unchecked Sendable {
    public let syllables: [String]
    public let syllableIndex: [String: UInt16]
    public let count: Int

    private let data: NSData
    private let base: UnsafeRawPointer
    private let offsets: UnsafeRawPointer
    private let entries: UnsafeRawPointer

    public enum LoadError: Error { case badFormat }

    public static func bundled() throws -> Lexicon {
        guard let url = Bundle.module.url(forResource: "PinyinLexicon", withExtension: "bin") else {
            throw LoadError.badFormat
        }
        return try Lexicon(contentsOf: url)
    }

    public init(contentsOf url: URL) throws {
        let data = try NSData(contentsOf: url, options: .alwaysMapped)
        self.data = data
        let base = data.bytes
        self.base = base
        func u32(_ at: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }
        guard data.length > 16,
              String(decoding: UnsafeRawBufferPointer(start: base, count: 4), as: UTF8.self) == "LDIM",
              u32(4) == 1 else { throw LoadError.badFormat }
        let syllableCount = u32(8), blobLength = u32(12)
        let blob = UnsafeRawBufferPointer(start: base + 16, count: blobLength)
        let names = blob.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard names.count == syllableCount else { throw LoadError.badFormat }
        syllables = names
        syllableIndex = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, UInt16($0)) })
        var cursor = 16 + blobLength
        cursor = (cursor + 3) & ~3
        count = u32(cursor)
        let entryBlobLength = u32(cursor + 4)
        offsets = base + cursor + 8
        entries = offsets + count * 4
        guard cursor + 8 + count * 4 + entryBlobLength <= data.length else { throw LoadError.badFormat }
    }

    @inline(__always) private func entry(_ i: Int) -> UnsafeRawPointer {
        entries + Int(offsets.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian)
    }

    /// 第 i 条的音节数。
    @inline(__always) public func length(_ i: Int) -> Int { Int(entry(i).load(as: UInt8.self)) }

    @inline(__always) public func syllableID(_ i: Int, at position: Int) -> UInt16 {
        entry(i).loadUnaligned(fromByteOffset: 1 + position * 2, as: UInt16.self).littleEndian
    }

    public func cost(_ i: Int) -> Int {
        let p = entry(i)
        return Int(p.loadUnaligned(fromByteOffset: 1 + length(i) * 2, as: UInt16.self).littleEndian)
    }

    public func word(_ i: Int) -> String {
        let p = entry(i)
        let at = 1 + length(i) * 2 + 2
        let n = Int(p.load(fromByteOffset: at, as: UInt8.self))
        return String(decoding: UnsafeRawBufferPointer(start: p + at + 1, count: n), as: UTF8.self)
    }

    public var all: Range<Int> { 0..<count }

    /// 在 `range`(其中条目的前 `depth` 个音节都相同)里取第 `depth` 个音节等于 `id` 的子区间。
    public func narrow(_ range: Range<Int>, depth: Int, id: UInt16) -> Range<Int> {
        let target = Int(id)
        // 音节数不超过 depth 的条目在这一位上没有音节,按 -1 排在最前。
        func key(_ i: Int) -> Int { length(i) > depth ? Int(syllableID(i, at: depth)) : -1 }
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(mid) < target { lo = mid + 1 } else { hi = mid }
        }
        let start = lo
        hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(mid) <= target { lo = mid + 1 } else { hi = mid }
        }
        return start..<lo
    }

    /// 按完整音节序列查词,按 cost 从低到高。测试与调试用。
    public func words(for syllables: [String]) -> [String] {
        var range = all
        for (depth, s) in syllables.enumerated() {
            guard let id = syllableIndex[s] else { return [] }
            range = narrow(range, depth: depth, id: id)
        }
        return range.prefix { length($0) == syllables.count }.map(word)
    }
}
