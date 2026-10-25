import XCTest
@testable import LodoIME
import LodoReranker

/// chinese-ime-lm 的评测集(不进仓库,先下载到一个目录):
///
///     LODO_IME_EVAL_DIR=<目录> swift test --filter IMEEvalTests
///
/// 目录里放 quanpin-words-v1.tsv、sentences-v1.tsv(https://github.com/metasequoiaime/chinese-ime-lm/tree/main/eval),
/// 另外总会跑仓库里自带的 Fixtures/lodo-sentences.tsv。
/// 报告写到 $LODO_IME_EVAL_LOG(默认 /tmp/lodo-ime-eval.log)。
final class IMEEvalTests: XCTestCase {
    struct Case { let id, input, gold: String; let tags: String }

    static func load(_ url: URL) -> [Case] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#"), !line.hasPrefix("id\t") else { return nil }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { return nil }
            return Case(id: f[0], input: f[1], gold: f[2], tags: f.count > 4 ? f[4] : "")
        }
    }

    struct Report {
        var n = 0, top1 = 0, top3 = 0, inList = 0
        var bySource: [String: (n: Int, top1: Int)] = [:]
        var misses: [String] = []
        mutating func add(_ c: Case, _ list: [Candidate]) {
            n += 1
            let rank = list.firstIndex { $0.text == c.gold }
            if rank == 0 { top1 += 1 }
            if let rank, rank < 3 { top3 += 1 }
            if rank != nil { inList += 1 }
            let src = list.first.map { "\($0.source)" } ?? "none"
            bySource[src, default: (0, 0)].n += 1
            if rank == 0 { bySource[src]!.top1 += 1 }
            if rank != 0 {
                misses.append("\(c.id)\t\(c.input)\t金:\(c.gold)\t排名:\(rank.map { String($0 + 1) } ?? "—")\t首选:\(list.first?.text ?? "")(\(src))\t\(c.tags)")
            }
        }
        func summary(_ name: String) -> String {
            func pct(_ a: Int) -> String { String(format: "%.3f", Double(a) / Double(max(n, 1))) }
            var s = "== \(name)  n=\(n)  top1=\(pct(top1))  top3=\(pct(top3))  在候选里=\(pct(inList))\n"
            for (k, v) in bySource.sorted(by: { $0.key < $1.key }) {
                s += "   首选来源 \(k): \(v.n) 例, top1 \(String(format: "%.3f", Double(v.top1) / Double(max(v.n, 1))))\n"
            }
            return s
        }
    }

    /// 有重排器时同一批用例再跑一遍,报"救回"(无重排错、有重排对)和"弄坏"分开数。
    func run(_ cases: [Case], name: String, log: inout String, listMisses: Bool) -> Report {
        let plain = PinyinEngine(lexicon: EngineTests.lexicon)
        var r = Report()
        let reranked = Self.reranker.map { PinyinEngine(lexicon: EngineTests.lexicon, reranker: $0) }
        var rr = Report()
        var rescued: [String] = [], broken: [String] = []
        var rerankTime: TimeInterval = 0
        for c in cases {
            let base = plain.candidates(for: c.input, limit: 60).candidates
            r.add(c, base)
            guard let reranked else { continue }
            let t0 = Date()
            let list = reranked.candidates(for: c.input, limit: 60).candidates
            rerankTime += Date().timeIntervalSince(t0)
            rr.add(c, list)
            let before = base.first?.text == c.gold, after = list.first?.text == c.gold
            if !before && after { rescued.append("\(c.id)\t\(c.gold)\t原首选:\(base.first?.text ?? "")") }
            if before && !after { broken.append("\(c.id)\t\(c.gold)\t重排后:\(list.first?.text ?? "")") }
        }
        log += r.summary(name + "(无重排)")
        if listMisses { log += r.misses.joined(separator: "\n") + "\n" }
        if reranked != nil {
            log += rr.summary(name + "(4M 重排)")
            log += "   救回 \(rescued.count) 例,弄坏 \(broken.count) 例,含重排每例平均 \(String(format: "%.1f", rerankTime * 1000 / Double(max(cases.count, 1)))) ms\n"
            log += rescued.map { "救回\t" + $0 }.joined(separator: "\n") + "\n"
            log += broken.map { "弄坏\t" + $0 }.joined(separator: "\n") + "\n"
            if listMisses { log += rr.misses.map { "重排后仍错\t" + $0 }.joined(separator: "\n") + "\n" }
        }
        return r
    }

    /// 包里自带的 4M 权重;LODO_IME_NO_RERANK=1 时不跑重排对比。
    static let reranker: ModelReranker? = ProcessInfo.processInfo.environment["LODO_IME_NO_RERANK"] == nil
        ? ModelReranker.bundled() : nil

    func testEvaluate() throws {
        var log = ""
        let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let own = Self.load(fixtures.appending(path: "lodo-sentences.tsv"))
        let ownReport = run(own, name: "lodo 日常句", log: &log, listMisses: true)

        if let dir = ProcessInfo.processInfo.environment["LODO_IME_EVAL_DIR"] {
            let base = URL(fileURLWithPath: dir)
            // 词级 2.5 万条要跑一分多钟,调整句时可以 LODO_IME_EVAL_SENTENCES_ONLY=1 跳过。
            if ProcessInfo.processInfo.environment["LODO_IME_EVAL_SENTENCES_ONLY"] == nil {
                let words = Self.load(base.appending(path: "quanpin-words-v1.tsv"))
                let w = run(words, name: "chinese-ime-lm 词级", log: &log, listMisses: false)
                log += w.misses.prefix(80).joined(separator: "\n") + "\n"
            }
            _ = run(Self.load(base.appending(path: "sentences-v1.tsv")), name: "chinese-ime-lm 整句", log: &log, listMisses: true)
        }
        let path = ProcessInfo.processInfo.environment["LODO_IME_EVAL_LOG"] ?? "/tmp/lodo-ime-eval.log"
        try log.write(toFile: path, atomically: true, encoding: .utf8)
        print(log.split(separator: "\n").filter { $0.hasPrefix("==") || $0.hasPrefix("   ") }.joined(separator: "\n"))
        XCTAssertGreaterThan(ownReport.n, 0)
    }
}

extension IMEEvalTests {
    /// 按键路径延迟:把 lodo 日常句逐个字母敲进去,每敲一下取一次候选,报 p50/p95/最大。
    func testKeystrokeLatency() throws {
        guard ProcessInfo.processInfo.environment["LODO_IME_EVAL_DIR"] != nil else { throw XCTSkip("评测时才跑") }
        let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let inputs = Self.load(fixtures.appending(path: "lodo-sentences.tsv")).map(\.input)
        func measure(_ engine: PinyinEngine) -> String {
            for s in inputs.prefix(5) { _ = engine.candidates(for: s) } // 预热:页面映射、模型首次触页
            var samples: [Double] = []
            for s in inputs {
                for n in 1...s.count {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = engine.candidates(for: String(s.prefix(n)))
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
            }
            samples.sort()
            func p(_ q: Double) -> Double { samples[min(samples.count - 1, Int(q * Double(samples.count)))] }
            return String(format: "%d 次按键 p50 %.1f ms  p95 %.1f ms  最大 %.1f ms", samples.count, p(0.5), p(0.95), samples.last ?? 0)
        }
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return Double(info.phys_footprint) / 1_048_576
        }
        let before = footprint()
        let fresh = ModelReranker.bundled()
        let after = footprint()
        _ = fresh?.best(context: "", candidates: [.init(text: "在", answersKey: true, trustedDictionaryHit: false),
                                                  .init(text: "再", answersKey: true, trustedDictionaryHit: false)])
        var log = String(format: "== 内存:载入 4M 重排器 +%.1f MB,跑过一次 +%.1f MB(进程共 %.1f MB)\n", after - before, footprint() - before, footprint())
        log += "== 按键延迟(无重排) " + measure(PinyinEngine(lexicon: EngineTests.lexicon)) + "\n"
        if let r = Self.reranker {
            log += "== 按键延迟(4M 重排) " + measure(PinyinEngine(lexicon: EngineTests.lexicon, reranker: r)) + "\n"
        }
        print(log)
    }
}
