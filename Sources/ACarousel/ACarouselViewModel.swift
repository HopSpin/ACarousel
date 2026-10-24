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

import SwiftUI
import Combine

@available(iOS 13.0, OSX 10.15, *)
class ACarouselViewModel<Data, ID>: ObservableObject where Data : RandomAccessCollection, ID : Hashable {
    
    /// external index
    @Binding
    private var index: Int
    
    private let _data: Data
    private let _dataId: KeyPath<Data.Element, ID>
    private let _spacing: CGFloat
    private let _headspace: CGFloat
    private let _isWrap: Bool
    private let _sidesScaling: CGFloat
    private let _autoScroll: ACarouselAutoScroll
    private let _canMove: Bool
    
    init(_ data: Data, id: KeyPath<Data.Element, ID>, index: Binding<Int>, spacing: CGFloat, headspace: CGFloat, sidesScaling: CGFloat, isWrap: Bool, autoScroll: ACarouselAutoScroll, isTimerActive: Binding<Bool>, flick: CGFloat, canMove: Bool) {

        /// The start slide is the external index clamped into the data:
        /// an index past the data lands on the last slide, a negative one
        /// on the first, empty data on 0 and nothing is rendered. The
        /// binding is read here, never written.
        let start = data.isEmpty ? 0 : min(max(index.wrappedValue, 0), data.count - 1)
        
        self._data = data
        self._dataId = id
        self._spacing = spacing
        self._headspace = headspace
        self._isWrap = isWrap
        self._sidesScaling = sidesScaling
        self._autoScroll = autoScroll
        self.isTimerActive = isTimerActive
        self.flick = flick
        self._canMove = canMove
        
        if data.count > 1 && isWrap {
            activeIndex = start + 1
        } else {
            activeIndex = start
        }

        self._index = index

        /// A view model is built on every body evaluation of the host. The
        /// wrap snap leaves the flag down so that its own rebuild — at the
        /// index it settled on — renders with no animation; a rebuild at any
        /// other index is an external navigation (a dot tap, a sibling's
        /// write) and animates.
        if !isAnimatedOffset && start != settledIndex {
            isAnimatedOffset = true
        }
    }
    
    
    /// The index of the currently active subview.
    @Published var activeIndex: Int = 0 {
        willSet {
            if isWrap {
                if newValue > _data.count || newValue == 0 {
                    return
                }
                index = newValue - 1
            } else {
                index = newValue
            }
        }
        didSet {
            changeOffset()
        }
    }
    
    /// Offset x of the view drag.
    @Published var dragOffset: CGFloat = .zero
    
    /// size of GeometryProxy
    var viewSize: CGSize = .zero
    
    
    /// Counting of time
    /// work when `isTimerActive` is true
    /// Toggles the active subviewview and resets if the count is the same as
    /// the duration of the auto scroll. Otherwise, increment one
    private var timing: TimeInterval = 0
    
    /// Define listen to the timer
    /// Ignores listen while dragging, and listen again after the drag is over
    /// Ignores listen when App will resign active, and listen again when it become active
    private var isTimerActive: Binding<Bool>
    func setTimerActive(_ active: Bool) {
        isTimerActive.wrappedValue = active
    }
    private var flick: CGFloat
}


extension ACarouselViewModel where ID == Data.Element.ID, Data.Element : Identifiable {
    
    convenience init(_ data: Data, index: Binding<Int>, spacing: CGFloat, headspace: CGFloat, sidesScaling: CGFloat, isWrap: Bool, autoScroll: ACarouselAutoScroll, isTimerActive: Binding<Bool>, flick: CGFloat, canMove: Bool) {
        self.init(data, id: \.id, index: index, spacing: spacing, headspace: headspace, sidesScaling: sidesScaling, isWrap: isWrap, autoScroll: autoScroll, isTimerActive: isTimerActive, flick: flick, canMove: canMove)
    }
}


extension ACarouselViewModel {
    
    var data: Data {
        guard _data.count != 0 else {
            return _data
        }
        guard _data.count > 1 else {
            return _data
        }
        guard isWrap else {
            return _data
        }
        return [_data.last!] + _data + [_data.first!] as! Data
    }
    
    var dataId: KeyPath<Data.Element, ID> {
        return _dataId
    }
    
    var spacing: CGFloat {
        return _spacing
    }
    
    var offsetAnimation: Animation? {
        guard isWrap else {
            return .spring()
        }
        return isAnimatedOffset ? .spring() : .none
    }
    
    var itemWidth: CGFloat {
        max(0, viewSize.width - defaultPadding * 2)
    }
    
    var timer: TimePublisher? {
        guard autoScroll.isActive else {
            return nil
        }
        return Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    }
    
    /// Defines the scaling based on whether the item is currently active or not.
    /// - Parameter item: The incoming item
    /// - Returns: scaling
    func itemScaling(_ item: Data.Element) -> CGFloat {
        guard activeIndex < data.count else {
            return 0
        }
        let activeItem = data[activeIndex as! Data.Index]
        return activeItem[keyPath: _dataId] == item[keyPath: _dataId] ? 1 : sidesScaling
    }
}

// MARK: - private variable
extension ACarouselViewModel {
    
    private var isWrap: Bool {
        return _data.count > 1 ? _isWrap : false
    }
    
    private var autoScroll: ACarouselAutoScroll {
        guard _data.count > 1 else { return .inactive }
        guard case let .active(t) = _autoScroll else { return _autoScroll }
        return t > 0 ? _autoScroll : .defaultActive
    }
    
    private var defaultPadding: CGFloat {
        return (_headspace + spacing)
    }
    
    private var itemActualWidth: CGFloat {
        itemWidth + spacing
    }
    
    private var sidesScaling: CGFloat {
        return max(min(_sidesScaling, 1), 0)
    }
    
    /// Is animated when view is in offset — process memory, see
    /// `ACarouselOffsetMemory`.
    private var isAnimatedOffset: Bool {
        get { ACarouselOffsetMemory.isAnimated }
        set { ACarouselOffsetMemory.isAnimated = newValue }
    }

    /// The external index the last wrap snap settled on — process memory,
    /// see `ACarouselOffsetMemory`.
    private var settledIndex: Int? {
        get { ACarouselOffsetMemory.settledIndex }
        set { ACarouselOffsetMemory.settledIndex = newValue }
    }
}

// MARK: - Offset Method
extension ACarouselViewModel {
    /// current offset value
    var offset: CGFloat {
        let activeOffset = CGFloat(activeIndex) * itemActualWidth
        return defaultPadding - activeOffset + dragOffset
    }
    
    /// change offset when acitveItem changes
    private func changeOffset() {
        isAnimatedOffset = true
        guard isWrap else {
            return
        }
        
        let minimumOffset = defaultPadding
        let maxinumOffset = defaultPadding - CGFloat(data.count - 1) * itemActualWidth
        
        if offset == minimumOffset {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                /// The external index read `0` when the edge copy was
                /// reached; if it has moved since (a dot tap, a list reset),
                /// the host has already rebuilt for it and this snap is stale.
                guard self.index == 0 else { return }
                self.settledIndex = self._data.count - 1
                self.activeIndex = self.data.count - 2
                self.isAnimatedOffset = false
            }
        } else if offset == maxinumOffset {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                /// The external index read `count - 1` when the edge copy
                /// was reached; if it has moved since, this snap is stale.
                guard self.index == self._data.count - 1 else { return }
                self.settledIndex = 0
                self.activeIndex = 1
                self.isAnimatedOffset = false
            }
        }
    }
}

// MARK: - Drag Gesture
extension ACarouselViewModel {
    /// drag gesture of view
    var dragGesture: some Gesture {
        DragGesture()
            .onChanged(dragChanged)
            .onEnded(dragEnded)
    }
    
    private func dragChanged(_ value: DragGesture.Value) {
        guard _canMove else { return }
        
        isAnimatedOffset = true
        
        /// Defines the maximum value of the drag
        /// Avoid dragging more than the values of multiple subviews at the end of the drag,
        /// and still only one subview is toggled
        var offset: CGFloat = itemActualWidth
        if value.translation.width > 0 {
            offset = min(offset, value.translation.width)
        } else {
            offset = max(-offset, value.translation.width)
        }
        
        /// set drag offset
        dragOffset = offset
        
        /// stop active timer
        isTimerActive.wrappedValue = false
    }
    
    private func dragEnded(_ value: DragGesture.Value) {
        guard _canMove else { return }
        /// reset drag offset
        dragOffset = .zero
        
        /// reset timing and restart active timer
        resetTiming()
        //isTimerActive = true

        let velocity = value.velocity.width
        let flick = abs(velocity) > self.flick

        /// Defines the drag threshold
        /// At the end of the drag, if the drag value exceeds the drag threshold,
        /// the active view will be toggled
        /// default is one third of subview
        let dragThreshold: CGFloat = itemWidth / 3
        
        var activeIndex = self.activeIndex
        if value.translation.width > dragThreshold || (flick && velocity > 0) {
            activeIndex -= 1
        }
        if value.translation.width < -dragThreshold || (flick && velocity < 0) {
            activeIndex += 1
        }
        self.activeIndex = max(0, min(activeIndex, data.count - 1))
    }
}

// MARK: - Receive Timer
extension ACarouselViewModel {
    
    /// timer change
    func receiveTimer(_ value: Timer.TimerPublisher.Output) {
        /// Ignores listen when `isTimerActive` is false.
        guard isTimerActive.wrappedValue else {
            return
        }
        /// increments of one and compare to the scrolling duration
        /// return when timing less than duration
        activeTiming()
        timing += 1
        if timing < autoScroll.interval {
            return
        }
        
        if activeIndex == data.count - 1 {
            /// `isWrap` is false.
            /// Revert to the first view after scrolling to the last view
            activeIndex = 0
        } else {
            /// `isWrap` is true.
            /// Incremental, calculation of offset by `offsetChanged(_: proxy:)`
            activeIndex += 1
        }
        resetTiming()
    }
    
    
    /// reset counting of time
    private func resetTiming() {
        timing = 0
    }
    
    /// time increments of one
    private func activeTiming() {
        timing += 1
    }
}


/// The one piece of state that outlives a view model. `ACarousel` builds a
/// new view model on every body evaluation of its host, so the animation
/// flag and the slide the last wrap snap settled on live here — for the
/// process, not on disk (the flag used to be a `UserDefaults` key, written
/// on every drag event and surviving a relaunch). `internal` so the
/// package's own tests can set and read it.
enum ACarouselOffsetMemory {

    /// Whether the next offset change animates (`.spring()`) or lands with
    /// no animation (`.none`). Raised by every `activeIndex` change and by
    /// a drag, lowered by the wrap snap once the strip has been moved to the
    /// real slide, and raised again by `init` for a rebuild at an index
    /// other than the settled one.
    static var isAnimated = false

    /// The external index the last wrap snap wrote: `0` after a forward
    /// wrap, `count - 1` after a backward one; `nil` until a snap has
    /// happened in this process.
    static var settledIndex: Int?
}
