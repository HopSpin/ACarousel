/**
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

import XCTest
import SwiftUI
@testable import ACarousel

/// Characterization pins for the HopSpin fork, from the L36-2 visit
/// (2026-10-24) on:
///
///  1. CLAMP: `init` clamps the external index into the data instead of
///     trapping — an index past the data seeds the last slide, a negative
///     one the first, empty data seeds 0 and renders nothing; the binding is
///     never written from `init`; every in-range index seeds `activeIndex`
///     exactly as before (wrap: index + 1; non-wrap: index).
///  2. MEMORY: the animation flag and the slide the last wrap snap settled
///     on live in the host's `ACarouselOffsetMemory` (L36-4: one per
///     carousel, handed to `init`; before that a process-wide static). A
///     rebuild inside the post-snap window at a DIFFERENT external index
///     raises the flag (animates); at the SAME index it stays down (the
///     snap's own rebuild); the first build on a fresh memory raises it; a
///     non-edge step raises it; non-wrap `offsetAnimation` is `.spring()`
///     whatever the flag.
///  3. SNAP: 0.1 s after an edge copy is reached, `activeIndex` moves to the
///     real slide, the external index is written (`0` forward, `count - 1`
///     backward), recorded as settled, and the flag is lowered.
///  4. STALE SNAP: a snap whose external index MOVED during the 0.1 s (a dot
///     tap, a list reset) does nothing — the moved value stands,
///     `activeIndex` stays on the edge copy, the flag stays up, nothing is
///     settled.
///  5. CADENCE (L36-3): `receiveTimer` counts one per tick, so `.active(n)`
///     advances on the n-th tick and again n ticks later (the inherited
///     double count advanced on the fourth tick of seven); a stopped timer
///     ignores ticks.
///  6. ISOLATION (L36-4): two view models with two memories never observe
///     each other — a snap in one lowers only its own flag, and a build on
///     the other at the first one's settled index still animates; two view
///     models handed the SAME memory are siblings, and the sibling built
///     for the snap's write, at the settled index, stays down.
///
/// Geometry: spacing 0 / headspace 0 and a 390-pt width, so one slide is one
/// `itemActualWidth` and the edge offsets are exact.
final class ACarouselViewModelPinTests: XCTestCase {

    private struct Slide: Identifiable, Equatable {
        let id: Int
    }

    /// A stand-in for the host's stored index: the view model reads and
    /// writes it through a `Binding`; the test reads and moves it directly.
    private final class ExternalIndex {
        var value: Int
        init(_ value: Int) { self.value = value }
        var binding: Binding<Int> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    /// `memory` defaults to a fresh one per call; a pin that reads or
    /// pre-sets the memory passes its own.
    private func makeViewModel(
        count: Int,
        index: ExternalIndex,
        isWrap: Bool = true,
        autoScroll: ACarouselAutoScroll = .inactive,
        isTimerActive: Bool = false,
        memory: ACarouselOffsetMemory = ACarouselOffsetMemory()
    ) -> ACarouselViewModel<[Slide], Int> {
        let viewModel = ACarouselViewModel(
            (0..<count).map { Slide(id: $0) },
            id: \.id,
            index: index.binding,
            spacing: 0,
            headspace: 0,
            sidesScaling: 1,
            isWrap: isWrap,
            autoScroll: autoScroll,
            isTimerActive: .constant(isTimerActive),
            flick: 500,
            canMove: true,
            offsetMemory: memory
        )
        viewModel.viewSize = CGSize(width: 390, height: 120)
        return viewModel
    }

    /// Spins the main run loop past the snap's 0.1 s dispatch.
    private func waitForTheSnapWindow() {
        let passed = expectation(description: "the 0.1 s snap window has passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { passed.fulfill() }
        wait(for: [passed], timeout: 2)
    }

    // MARK: - 1. The clamp

    func test_init_inRangeIndex_seedsActiveIndexAsBefore() {
        for index in 0..<3 {
            let external = ExternalIndex(index)
            XCTAssertEqual(makeViewModel(count: 3, index: external, isWrap: true).activeIndex, index + 1, "wrap: the real slide in the padded strip")
            XCTAssertEqual(makeViewModel(count: 3, index: external, isWrap: false).activeIndex, index, "non-wrap: the index itself")
            XCTAssertEqual(external.value, index, "the binding is read, never written")
        }
    }

    func test_init_indexPastTheData_landsOnTheLastSlide_withoutWritingBack() {
        let external = ExternalIndex(5)
        XCTAssertEqual(makeViewModel(count: 2, index: external, isWrap: true).activeIndex, 2)
        XCTAssertEqual(makeViewModel(count: 2, index: external, isWrap: false).activeIndex, 1)
        XCTAssertEqual(external.value, 5, "the stale value is the host's to keep in range (HopSpin clamps on read)")
    }

    func test_init_negativeIndex_landsOnTheFirstSlide_withoutWritingBack() {
        let external = ExternalIndex(-1)
        XCTAssertEqual(makeViewModel(count: 2, index: external, isWrap: true).activeIndex, 1)
        XCTAssertEqual(makeViewModel(count: 2, index: external, isWrap: false).activeIndex, 0)
        XCTAssertEqual(external.value, -1)
    }

    func test_init_emptyData_doesNotTrap_andRendersNothing() {
        let external = ExternalIndex(3)
        let viewModel = makeViewModel(count: 0, index: external)
        XCTAssertEqual(viewModel.activeIndex, 0)
        XCTAssertTrue(viewModel.data.isEmpty, "no padding without items")
        XCTAssertNil(viewModel.timer, "no auto-scroll without items")
        XCTAssertEqual(viewModel.offset, 0)
        XCTAssertEqual(external.value, 3)
    }

    // MARK: - 2. The flag and the settled index

    func test_offsetAnimation_nonWrap_isSpringWhateverTheFlag() {
        let memory = ACarouselOffsetMemory()
        let viewModel = makeViewModel(count: 3, index: ExternalIndex(0), isWrap: false, memory: memory)
        memory.isAnimated = false
        XCTAssertNotNil(viewModel.offsetAnimation)
        memory.isAnimated = true
        XCTAssertNotNil(viewModel.offsetAnimation)
    }

    func test_offsetAnimation_wrap_followsTheFlag() {
        let memory = ACarouselOffsetMemory()
        let viewModel = makeViewModel(count: 3, index: ExternalIndex(0), isWrap: true, memory: memory)
        memory.isAnimated = false
        XCTAssertNil(viewModel.offsetAnimation, "flag down: the offset change lands with no animation")
        memory.isAnimated = true
        XCTAssertNotNil(viewModel.offsetAnimation, "flag up: the offset change springs")
    }

    func test_init_firstBuildOnAFreshMemory_raisesTheFlag() {
        let memory = ACarouselOffsetMemory()
        XCTAssertFalse(memory.isAnimated)
        XCTAssertNil(memory.settledIndex)
        _ = makeViewModel(count: 2, index: ExternalIndex(0), memory: memory)
        XCTAssertTrue(memory.isAnimated)
        XCTAssertNil(memory.settledIndex, "a build settles nothing")
    }

    func test_init_insideThePostSnapWindow_aDifferentIndexRaisesTheFlag() {
        let memory = ACarouselOffsetMemory()
        memory.isAnimated = false
        memory.settledIndex = 0
        let viewModel = makeViewModel(count: 2, index: ExternalIndex(1), memory: memory)
        XCTAssertTrue(memory.isAnimated, "an external navigation inside the window animates (the dot-tap jump)")
        XCTAssertNotNil(viewModel.offsetAnimation)
    }

    func test_init_insideThePostSnapWindow_theSameIndexKeepsTheFlagDown() {
        let memory = ACarouselOffsetMemory()
        memory.isAnimated = false
        memory.settledIndex = 0
        let viewModel = makeViewModel(count: 2, index: ExternalIndex(0), memory: memory)
        XCTAssertFalse(memory.isAnimated, "the snap's own rebuild stays invisible")
        XCTAssertNil(viewModel.offsetAnimation)
    }

    func test_nonEdgeStep_raisesTheFlag() {
        let memory = ACarouselOffsetMemory()
        let viewModel = makeViewModel(count: 3, index: ExternalIndex(0), memory: memory)
        memory.isAnimated = false
        viewModel.activeIndex = 2
        XCTAssertTrue(memory.isAnimated)
    }

    // MARK: - 3. The snaps

    func test_forwardSnap_settlesOnTheFirstSlide_flagDown() {
        let memory = ACarouselOffsetMemory()
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 2, index: external, memory: memory)
        viewModel.activeIndex = 2   // the tick to slide 2
        XCTAssertEqual(external.value, 1)
        viewModel.activeIndex = 3   // the tick onto the edge copy of slide 1
        XCTAssertEqual(external.value, 1, "an edge copy is not written through")
        waitForTheSnapWindow()
        XCTAssertEqual(viewModel.activeIndex, 1, "snapped to the real slide 1")
        XCTAssertEqual(external.value, 0)
        XCTAssertEqual(memory.settledIndex, 0)
        XCTAssertFalse(memory.isAnimated)
    }

    func test_backwardSnap_settlesOnTheLastSlide_flagDown() {
        let memory = ACarouselOffsetMemory()
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 3, index: external, memory: memory)
        viewModel.activeIndex = 0   // a drag onto the edge copy of slide 3
        XCTAssertEqual(external.value, 0, "an edge copy is not written through")
        waitForTheSnapWindow()
        XCTAssertEqual(viewModel.activeIndex, 3, "snapped to the real slide 3")
        XCTAssertEqual(external.value, 2)
        XCTAssertEqual(memory.settledIndex, 2)
        XCTAssertFalse(memory.isAnimated)
    }

    // MARK: - 4. A stale snap does nothing

    func test_forwardSnap_isSkipped_whenTheExternalIndexMovedInTheWindow() {
        let memory = ACarouselOffsetMemory()
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 3, index: external, memory: memory)
        viewModel.activeIndex = 3   // slide 3 (external 2)
        viewModel.activeIndex = 4   // the edge copy of slide 1
        external.value = 1          // a dot tap inside the 0.1 s
        waitForTheSnapWindow()
        XCTAssertEqual(external.value, 1, "the tap stands; the snap did not write 0 over it")
        XCTAssertEqual(viewModel.activeIndex, 4, "the stale view model did not move")
        XCTAssertNil(memory.settledIndex)
        XCTAssertTrue(memory.isAnimated)
    }

    func test_backwardSnap_isSkipped_whenTheExternalIndexMovedInTheWindow() {
        let memory = ACarouselOffsetMemory()
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 3, index: external, memory: memory)
        viewModel.activeIndex = 0   // the edge copy of slide 3
        external.value = 1          // a dot tap inside the 0.1 s
        waitForTheSnapWindow()
        XCTAssertEqual(external.value, 1, "the tap stands; the snap did not write 2 over it")
        XCTAssertEqual(viewModel.activeIndex, 0)
        XCTAssertNil(memory.settledIndex)
        XCTAssertTrue(memory.isAnimated)
    }

    // MARK: - 5. The cadence (L36-3)

    func test_receiveTimer_advancesOnTheIntervalsTick_andAgainOneIntervalLater() {
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 3, index: external, autoScroll: .active(5), isTimerActive: true)
        for tick in 1...4 {
            viewModel.receiveTimer(Date())
            XCTAssertEqual(viewModel.activeIndex, 1, "tick \(tick) of 5: no advance yet")
        }
        viewModel.receiveTimer(Date())
        XCTAssertEqual(viewModel.activeIndex, 2, "the fifth tick advances (the inherited double count advanced on the fourth tick of seven)")
        XCTAssertEqual(external.value, 1)
        for tick in 6...9 {
            viewModel.receiveTimer(Date())
            XCTAssertEqual(viewModel.activeIndex, 2, "tick \(tick): the count restarted at the advance")
        }
        viewModel.receiveTimer(Date())
        XCTAssertEqual(viewModel.activeIndex, 3, "the tenth tick advances again")
        XCTAssertEqual(external.value, 2)
    }

    func test_receiveTimer_ignoresTicksWhileTheTimerIsStopped() {
        let external = ExternalIndex(0)
        let viewModel = makeViewModel(count: 3, index: external, autoScroll: .active(5), isTimerActive: false)
        for _ in 1...12 {
            viewModel.receiveTimer(Date())
        }
        XCTAssertEqual(viewModel.activeIndex, 1, "a stopped timer never advances")
        XCTAssertEqual(external.value, 0)
    }

    // MARK: - 6. One memory per host (L36-4)

    func test_twoMemories_aSnapInOneCarousel_leavesTheOthersFlagUp() {
        let bannerMemory = ACarouselOffsetMemory()
        let detailMemory = ACarouselOffsetMemory()
        let banner = makeViewModel(count: 2, index: ExternalIndex(0), memory: bannerMemory)
        _ = makeViewModel(count: 3, index: ExternalIndex(0), memory: detailMemory)
        XCTAssertTrue(detailMemory.isAnimated, "the detail's first build raised its own flag")
        banner.activeIndex = 2      // the tick to slide 2
        banner.activeIndex = 3      // the tick onto the edge copy of slide 1
        waitForTheSnapWindow()
        XCTAssertEqual(bannerMemory.settledIndex, 0)
        XCTAssertFalse(bannerMemory.isAnimated, "the banner's snap lowered the banner's flag")
        XCTAssertTrue(detailMemory.isAnimated, "and never reached the detail's")
        XCTAssertNil(detailMemory.settledIndex)
    }

    func test_twoMemories_aBuildAtTheOtherCarouselsSettledIndex_stillAnimates() {
        let bannerMemory = ACarouselOffsetMemory()
        bannerMemory.isAnimated = false
        bannerMemory.settledIndex = 0        // the banner just snapped forward
        let detailMemory = ACarouselOffsetMemory()
        detailMemory.isAnimated = false
        detailMemory.settledIndex = 2        // the detail's own snap, earlier
        let detail = makeViewModel(count: 3, index: ExternalIndex(0), memory: detailMemory)
        XCTAssertTrue(detailMemory.isAnimated, "0 is the banner's settled index, not this memory's: an external navigation, animated (one static would have kept it down)")
        XCTAssertNotNil(detail.offsetAnimation)
        XCTAssertFalse(bannerMemory.isAnimated, "untouched")
        XCTAssertEqual(bannerMemory.settledIndex, 0)
    }

    func test_oneMemorySharedOnPurpose_theSiblingBuiltForTheSnapsWrite_staysDown() {
        let surfaceMemory = ACarouselOffsetMemory()
        let shared = ExternalIndex(0)
        let frontmost = makeViewModel(count: 2, index: shared, memory: surfaceMemory)
        frontmost.activeIndex = 2   // the tick to slide 2
        frontmost.activeIndex = 3   // the tick onto the edge copy of slide 1
        waitForTheSnapWindow()
        XCTAssertEqual(shared.value, 0, "the snap wrote the shared index")
        let sibling = makeViewModel(count: 2, index: shared, memory: surfaceMemory)
        XCTAssertFalse(surfaceMemory.isAnimated, "a sibling built at the settled index renders the snap's write without animation")
        XCTAssertNil(sibling.offsetAnimation)
        let navigated = makeViewModel(count: 2, index: ExternalIndex(1), memory: surfaceMemory)
        XCTAssertTrue(surfaceMemory.isAnimated, "a sibling built at any other index animates")
        XCTAssertNotNil(navigated.offsetAnimation)
    }
}
