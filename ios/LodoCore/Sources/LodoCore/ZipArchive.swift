import Foundation
import Compression

/// 手写的最小 zip 容器读写(不引第三方库,Foundation 在 iOS/macOS 上没有公开的
/// 创建/读取 zip 的高层 API)。写入统一用 STORE(不压缩)——备份的大头是已经
/// 压缩过的图片/PDF 附件,DEFLATE 收益低、复杂度高,不值得为这个用途冒风险;
/// 读取同时兼容 STORE 与 DEFLATE,因为导入的 zip 不一定是本 app 自己写的
/// (用户可能解压改完用 Finder 重新压缩,Finder 默认用 DEFLATE)。
public enum ZipArchive {
    public struct Entry {
        public let path: String
        public let data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public enum ZipError: LocalizedError {
        case invalidFormat
        case unsupportedMethod
        case decompressionFailed

        public var errorDescription: String? {
            switch self {
            case .invalidFormat: return "不是有效的 zip 文件"
            case .unsupportedMethod: return "zip 里有不支持的压缩方式"
            case .decompressionFailed: return "zip 内容解压失败"
            }
        }
    }

    // MARK: - 写

    public static func write(_ entries: [Entry]) -> Data {
        struct CentralRecord {
            let nameData: Data
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
            let dosTime: UInt16
            let dosDate: UInt16
        }

        var output = Data()
        var centralRecords: [CentralRecord] = []
        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            var local = Data()
            local.appendUInt32LE(0x0403_4b50)
            local.appendUInt16LE(20)       // version needed to extract
            local.appendUInt16LE(0x0800)   // general purpose flag: 文件名按 UTF-8
            local.appendUInt16LE(0)        // compression method: store
            local.appendUInt16LE(dosTime)
            local.appendUInt16LE(dosDate)
            local.appendUInt32LE(crc)
            local.appendUInt32LE(size)     // compressed size(store 下等于原始大小)
            local.appendUInt32LE(size)     // uncompressed size
            local.appendUInt16LE(UInt16(nameData.count))
            local.appendUInt16LE(0)        // extra field length
            local.append(nameData)
            local.append(entry.data)
            output.append(local)

            centralRecords.append(CentralRecord(
                nameData: nameData, crc: crc, size: size, offset: offset,
                dosTime: dosTime, dosDate: dosDate))
        }

        let centralStart = UInt32(output.count)
        for record in centralRecords {
            var central = Data()
            central.appendUInt32LE(0x0201_4b50)
            central.appendUInt16LE(20)     // version made by
            central.appendUInt16LE(20)     // version needed to extract
            central.appendUInt16LE(0x0800)
            central.appendUInt16LE(0)      // method: store
            central.appendUInt16LE(record.dosTime)
            central.appendUInt16LE(record.dosDate)
            central.appendUInt32LE(record.crc)
            central.appendUInt32LE(record.size)
            central.appendUInt32LE(record.size)
            central.appendUInt16LE(UInt16(record.nameData.count))
            central.appendUInt16LE(0)      // extra field length
            central.appendUInt16LE(0)      // file comment length
            central.appendUInt16LE(0)      // disk number start
            central.appendUInt16LE(0)      // internal file attributes
            central.appendUInt32LE(0)      // external file attributes
            central.appendUInt32LE(record.offset)
            central.append(record.nameData)
            output.append(central)
        }
        let centralSize = UInt32(output.count) - centralStart

        var eocd = Data()
        eocd.appendUInt32LE(0x0605_4b50)
        eocd.appendUInt16LE(0)                              // disk number
        eocd.appendUInt16LE(0)                              // disk with central dir
        eocd.appendUInt16LE(UInt16(centralRecords.count))   // records on this disk
        eocd.appendUInt16LE(UInt16(centralRecords.count))   // total records
        eocd.appendUInt32LE(centralSize)
        eocd.appendUInt32LE(centralStart)
        eocd.appendUInt16LE(0)                              // comment length
        output.append(eocd)

        return output
    }

    // MARK: - 读

    public static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocdOffset = findEOCD(bytes) else { throw ZipError.invalidFormat }
        guard eocdOffset + 22 <= bytes.count else { throw ZipError.invalidFormat }

        let recordCount = Int(readUInt16LE(bytes, eocdOffset + 10))
        let centralOffset = Int(readUInt32LE(bytes, eocdOffset + 16))

        var entries: [Entry] = []
        var pos = centralOffset
        for _ in 0..<recordCount {
            guard pos + 46 <= bytes.count,
                  readUInt32LE(bytes, pos) == 0x0201_4b50 else {
                throw ZipError.invalidFormat
            }
            let method = Int(readUInt16LE(bytes, pos + 10))
            let compSize = Int(readUInt32LE(bytes, pos + 20))
            let uncompSize = Int(readUInt32LE(bytes, pos + 24))
            let nameLen = Int(readUInt16LE(bytes, pos + 28))
            let extraLen = Int(readUInt16LE(bytes, pos + 30))
            let commentLen = Int(readUInt16LE(bytes, pos + 32))
            let localOffset = Int(readUInt32LE(bytes, pos + 42))
            guard pos + 46 + nameLen <= bytes.count else { throw ZipError.invalidFormat }
            let name = String(decoding: bytes[(pos + 46)..<(pos + 46 + nameLen)], as: UTF8.self)

            guard localOffset + 30 <= bytes.count,
                  readUInt32LE(bytes, localOffset) == 0x0403_4b50 else {
                throw ZipError.invalidFormat
            }
            let localNameLen = Int(readUInt16LE(bytes, localOffset + 26))
            let localExtraLen = Int(readUInt16LE(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= bytes.count else { throw ZipError.invalidFormat }
            let compressedBytes = Array(bytes[dataStart..<(dataStart + compSize)])

            let content: Data
            switch method {
            case 0:
                content = Data(compressedBytes)
            case 8:
                guard let inflated = inflateRaw(compressedBytes, uncompressedSize: uncompSize) else {
                    throw ZipError.decompressionFailed
                }
                content = inflated
            default:
                throw ZipError.unsupportedMethod
            }
            entries.append(Entry(path: name, data: content))
            pos += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 从文件末尾往前找 EOCD 签名(注释字段最长 65535 字节,往前找这么远足够)。
    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let searchStart = max(0, bytes.count - 22 - 65535)
        var i = bytes.count - 22
        while i >= searchStart {
            if readUInt32LE(bytes, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func inflateRaw(_ compressed: [UInt8], uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: uncompressedSize)
        let produced = destination.withUnsafeMutableBufferPointer { destBuffer -> Int in
            guard let destBase = destBuffer.baseAddress else { return 0 }
            return compressed.withUnsafeBufferPointer { srcBuffer -> Int in
                guard let srcBase = srcBuffer.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase, uncompressedSize, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == uncompressedSize else { return nil }
        return Data(destination)
    }

    // MARK: - CRC32(标准 zip/ISO-3309,多项式 0xEDB88320)

    private static let crcTable: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - MS-DOS 日期/时间(zip 格式要求)

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(max(0, (comps.year ?? 1980) - 1980))
        let month = UInt16(comps.month ?? 1)
        let day = UInt16(comps.day ?? 1)
        let hour = UInt16(comps.hour ?? 0)
        let minute = UInt16(comps.minute ?? 0)
        let second = UInt16(comps.second ?? 0)
        let dosDate = (year << 9) | (month << 5) | day
        let dosTime = (hour << 11) | (minute << 5) | (second / 2)
        return (dosTime, dosDate)
    }
}

// MARK: - 小端读写辅助

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

private func readUInt16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
}
