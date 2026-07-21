import XCTest
@testable import LodoCore

/// ZipArchive 写入/读取往返测试;真实跨工具兼容性(Finder/unzip 能否打开)
/// 不在单测范围内,另外用命令行手动验证过。
final class ZipArchiveTests: XCTestCase {
    func testRoundTripPreservesContent() throws {
        let entries = [
            ZipArchive.Entry(path: "manifest.json", data: Data(#"{"a":1}"#.utf8)),
            ZipArchive.Entry(path: "files/图片.png", data: Data((0..<500).map { UInt8($0 % 256) })),
            ZipArchive.Entry(path: "empty.txt", data: Data()),
        ]
        let zipped = ZipArchive.write(entries)
        let readBack = try ZipArchive.read(zipped)

        XCTAssertEqual(readBack.count, entries.count)
        for entry in entries {
            guard let match = readBack.first(where: { $0.path == entry.path }) else {
                XCTFail("missing entry \(entry.path)")
                continue
            }
            XCTAssertEqual(match.data, entry.data, "content mismatch for \(entry.path)")
        }
    }

    func testEmptyArchive() throws {
        let zipped = ZipArchive.write([])
        let readBack = try ZipArchive.read(zipped)
        XCTAssertTrue(readBack.isEmpty)
    }

    func testLargerEntrySurvivesRoundTrip() throws {
        let bigData = Data((0..<200_000).map { UInt8(($0 * 7) % 256) })
        let zipped = ZipArchive.write([ZipArchive.Entry(path: "big.bin", data: bigData)])
        let readBack = try ZipArchive.read(zipped)
        XCTAssertEqual(readBack.first?.data, bigData)
    }

    func testReadInvalidDataThrows() {
        XCTAssertThrowsError(try ZipArchive.read(Data("not a zip".utf8)))
    }

    func testCRC32KnownVector() {
        // "123456789" 的 CRC-32(ISO-3309)是公开可验证的标准测试向量
        XCTAssertEqual(ZipArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    /// 读取兼容性:这个 fixture 是命令行 `zip`(Info-ZIP,真实 DEFLATE 压缩,
    /// 不是本项目自己写的)生成的,验证 ZipArchive.read 真的能解出别的工具压缩的
    /// zip——不是只有自己的 write() 配自己的 read() 才能用的自欺欺人格式。
    func testReadsRealDeflateZipFromExternalTool() throws {
        let base64 = """
        UEsDBBQAAAAIAMy79VyeWNrgFwAAAIkTAAAHABwAYmlnLnR4dFVUCQADkJBfapCQX2p1eAsAAQT1\
        AQAABAAAAADtwSEBAAAAAqDuYue7wga0AAAAAMBbBlBLAwQUAAAACADMu/VcG4j8cm4AAACVAAAA\
        DQAcAG1hbmlmZXN0Lmpzb25VVAkAA5CQX2qQkF9qdXgLAAEE9QEAAAQAAAAAq1ZKyy/KTSwJSy0q\
        zszPU7Iy1FHKSM3JyVeyUnqxf+azGeuf7Gh4tm7r8ykrns1d+mxr94v1U5/2dT/fs/L5rJYnO9Y+\
        m9YOQnPW6Lxs7326pBeo+smOblzsp4vmPe1a8HLq/qe7luFiK9VyAQBQSwECHgMUAAAACADMu/Vc\
        nlja4BcAAACJEwAABwAYAAAAAAABAAAApIEAAAAAYmlnLnR4dFVUBQADkJBfanV4CwABBPUBAAAE\
        AAAAAFBLAQIeAxQAAAAIAMy79VwbiPxybgAAAJUAAAANABgAAAAAAAEAAACkgVgAAABtYW5pZmVz\
        dC5qc29uVVQFAAOQkF9qdXgLAAEE9QEAAAQAAAAAUEsFBgAAAAACAAIAoAAAAA0BAAAAAA==
        """
        let zipData = try XCTUnwrap(Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")))
        let entries = try ZipArchive.read(zipData)
        XCTAssertEqual(entries.count, 2)

        guard let bigTxt = entries.first(where: { $0.path == "big.txt" }) else {
            return XCTFail("missing big.txt")
        }
        XCTAssertEqual(bigTxt.data, Data((String(repeating: "x", count: 5000) + "\n").utf8))

        guard let manifest = entries.first(where: { $0.path == "manifest.json" }) else {
            return XCTFail("missing manifest.json")
        }
        let manifestText = try XCTUnwrap(String(data: manifest.data, encoding: .utf8))
        XCTAssertTrue(manifestText.contains("这是一段用来测试压缩的中文文本"))
    }
}
