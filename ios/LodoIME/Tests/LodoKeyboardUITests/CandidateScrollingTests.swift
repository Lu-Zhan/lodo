#if os(iOS)
import XCTest
import UIKit
@testable import LodoKeyboardUI

@MainActor
final class CandidateScrollingTests: XCTestCase {
    private func choices(_ prefix: String = "候选") -> [CandidateChoice] {
        (0..<24).map { .suggestion("\(prefix)\($0)") }
    }

    private func bar() -> (CandidateBarView, CandidateScrollView) {
        let bar = CandidateBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 48))
        bar.show(preedit: nil, composing: true, choices: choices())
        bar.layoutIfNeeded()
        return (bar, bar.subviews.compactMap { $0 as? CandidateScrollView }.first!)
    }

    private func buttons(_ scroll: CandidateScrollView) -> [CandidateButton] {
        scroll.subviews.compactMap { $0 as? CandidateButton }.filter { !$0.isHidden }
    }

    private func nextMainTurn() async {
        let done = expectation(description: "滚动结束回调")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }

    func testCandidatesFreezeThroughDragAndDeceleration() async {
        let (bar, scroll) = bar()
        let original = buttons(scroll).map(\.accessibilityLabel)
        let originalSize = scroll.contentSize
        scroll.scrollViewWillBeginDragging(scroll)
        bar.show(preedit: nil, composing: true, choices: choices("新词"), resetScrollOnChange: false)
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: true)
        await nextMainTurn()
        bar.layoutIfNeeded()
        XCTAssertEqual(buttons(scroll).map(\.accessibilityLabel), original)
        XCTAssertEqual(scroll.contentSize, originalSize)
        bar.show(preedit: nil, composing: true, choices: choices("最终"), resetScrollOnChange: false)
        scroll.scrollViewDidEndDecelerating(scroll)
        await nextMainTurn()
        bar.layoutIfNeeded()
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "最终0")
    }

    func testPendingResetSurvivesLaterRerank() async {
        let (bar, scroll) = bar()
        scroll.contentOffset.x = 250
        scroll.scrollViewWillBeginDragging(scroll)
        bar.show(preedit: nil, composing: true, choices: choices("新输入"), resetScrollOnChange: true)
        bar.show(preedit: nil, composing: true, choices: choices("新首选"), resetScrollOnChange: false)
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: false)
        await nextMainTurn()
        bar.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.x, 0)
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "新首选0")
    }

    func testRerankKeepsVisibleCandidateInPlace() {
        let (bar, scroll) = bar()
        let anchor = buttons(scroll)[6]
        scroll.contentOffset.x = anchor.frame.minX + 9
        let reordered = [.suggestion("新加入的长短语")] + choices()
        bar.show(preedit: nil, composing: true, choices: reordered, resetScrollOnChange: false)
        bar.layoutIfNeeded()
        let moved = buttons(scroll).first { $0.accessibilityLabel == "候选6" }!
        XCTAssertEqual(scroll.contentOffset.x - moved.frame.minX, 9, accuracy: 0.5)
    }

    func testScrollingDoesNotRemeasureOrMoveCandidateFrames() {
        let (bar, scroll) = bar()
        let initialFrames = buttons(scroll).map(\.frame)
        #if DEBUG
        let measurements = buttons(scroll).map(\.widthMeasurementCount)
        #endif
        for frame in 0..<240 {
            scroll.contentOffset.x = CGFloat(frame % 120) * 4
            bar.setNeedsLayout()
            bar.layoutIfNeeded()
        }
        #if DEBUG
        XCTAssertEqual(buttons(scroll).map(\.widthMeasurementCount), measurements)
        #endif
        XCTAssertEqual(buttons(scroll).map(\.frame), initialFrames)
        // 尺寸变化仍会正确重排,不会因缓存锁住旧行高。
        bar.frame.size.height = 60
        bar.layoutIfNeeded()
        XCTAssertTrue(buttons(scroll).allSatisfy { $0.frame.height == 60 })
    }

    func testExpandedCandidatesAlsoWaitForScrollToStop() async {
        let grid = CandidateGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        grid.show(choices())
        grid.layoutIfNeeded()
        let scroll = grid.subviews.compactMap { $0 as? CandidateScrollView }.first!
        scroll.scrollViewWillBeginDragging(scroll)
        grid.show(choices("新词"))
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "候选0")
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: false)
        await nextMainTurn()
        grid.layoutIfNeeded()
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "新词0")
    }

    func testSelectionUsesDisplayedChoiceWhileUpdateIsDeferred() async {
        let grid = CandidateGridView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        var selected: CandidateChoice?
        grid.onSelect = { selected = $0 }
        grid.show(choices())
        grid.layoutIfNeeded()
        let scroll = grid.subviews.compactMap { $0 as? CandidateScrollView }.first!
        scroll.scrollViewWillBeginDragging(scroll)
        grid.show(choices("新词"))
        buttons(scroll)[2].sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(selected, .suggestion("候选2"))
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: false)
        await nextMainTurn()
        grid.layoutIfNeeded()
        buttons(scroll)[2].sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(selected, .suggestion("新词2"))
    }

    /// 甩出去还在滑时打了新字母:不等滑完,当场换上新候选并回到开头。
    func testNewInputInterruptsCoasting() {
        let (bar, scroll) = bar()
        scroll.contentOffset.x = 300
        scroll.scrollViewWillBeginDragging(scroll)
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: true)
        XCTAssertTrue(scroll.isCoasting)
        bar.show(preedit: nil, composing: true, choices: choices("新输入"), resetScrollOnChange: true)
        bar.layoutIfNeeded()
        XCTAssertFalse(scroll.isCoasting)
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "新输入0")
        XCTAssertEqual(scroll.contentOffset.x, 0)
    }

    /// 同一串拼音的重排不打断惯性:照旧等滑完再换,免得看着的词跳走。
    func testRerankStillWaitsForCoasting() {
        let (bar, scroll) = bar()
        scroll.scrollViewWillBeginDragging(scroll)
        scroll.scrollViewDidEndDragging(scroll, willDecelerate: true)
        bar.show(preedit: nil, composing: true, choices: choices("重排"), resetScrollOnChange: false)
        bar.layoutIfNeeded()
        XCTAssertEqual(buttons(scroll).first?.accessibilityLabel, "候选0")
    }

    private final class Recorder: CandidateBarDelegate {
        var selected: [CandidateChoice] = []
        func candidateBar(select choice: CandidateChoice) { selected.append(choice) }
        func candidateBarToggleExpanded() {}
        func candidateBarAsk() {}
    }

    /// 惯性快停时点到的词:按钮自己没收到这一下就替它选;按钮已经选过就不再选一遍。
    func testCoastingTapSelectsOnce() async {
        let (bar, scroll) = bar()
        let recorder = Recorder()
        bar.delegate = recorder
        let target = buttons(scroll)[3]
        scroll.onCoastingTap?(target)
        await nextMainTurn()
        XCTAssertEqual(recorder.selected, [.suggestion("候选3")])
        target.sendActions(for: .primaryActionTriggered) // 按钮自己也选了一次
        scroll.onCoastingTap?(target)
        await nextMainTurn()
        XCTAssertEqual(recorder.selected, [.suggestion("候选3"), .suggestion("候选3")])
    }
}
#endif
