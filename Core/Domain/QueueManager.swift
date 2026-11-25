import Foundation
import Observation

enum RepeatMode: String, Sendable, Equatable, CaseIterable {
    case off
    case all
    case one
}

enum QueuePreviousAction: Equatable, Sendable {
    case restartCurrent
    case playPrevious(VideoItem)
    case none
}

@MainActor
protocol QueueManagerProtocol: AnyObject {
    var items: [VideoItem] { get }
    var currentIndex: Int? { get }
    var currentItem: VideoItem? { get }
    var repeatMode: RepeatMode { get set }
    var isShuffled: Bool { get set }
    func replaceQueue(with items: [VideoItem], startIndex: Int)
    func enqueueNext(_ item: VideoItem)
    func append(_ item: VideoItem)
    func remove(at index: Int)
    func move(from source: IndexSet, to destination: Int)
    func advanceToNext() -> VideoItem?
    func previousAction(currentPlaybackTime: TimeInterval) -> QueuePreviousAction
}

/// Manages playback ordering, non-destructive shuffle toggling, repeat modes, and 3-second previous behavior.
@MainActor
@Observable
final class QueueManager: QueueManagerProtocol {
    private(set) var items: [VideoItem] = []
    private(set) var currentIndex: Int?
    var repeatMode: RepeatMode = .off

    private var originalItems: [VideoItem] = []

    var isShuffled: Bool = false {
        didSet {
            guard oldValue != isShuffled else { return }
            applyShuffleStateChange()
        }
    }

    var currentItem: VideoItem? {
        guard let idx = currentIndex, items.indices.contains(idx) else { return nil }
        return items[idx]
    }

    init() {}

    func replaceQueue(with newItems: [VideoItem], startIndex: Int) {
        originalItems = newItems
        guard !newItems.isEmpty else {
            items = []
            currentIndex = nil
            return
        }

        let clampedStart = min(max(0, startIndex), newItems.count - 1)
        if isShuffled {
            let active = newItems[clampedStart]
            var rest = newItems
            rest.remove(at: clampedStart)
            rest.shuffle()
            items = [active] + rest
            currentIndex = 0
        } else {
            items = newItems
            currentIndex = clampedStart
        }
    }

    func enqueueNext(_ item: VideoItem) {
        if items.isEmpty {
            replaceQueue(with: [item], startIndex: 0)
            return
        }
        let insertIdx = (currentIndex ?? -1) + 1
        let clamped = min(max(0, insertIdx), items.count)
        items.insert(item, at: clamped)
        if !isShuffled {
            originalItems = items
        } else {
            originalItems.append(item)
        }
    }

    func append(_ item: VideoItem) {
        if items.isEmpty {
            replaceQueue(with: [item], startIndex: 0)
            return
        }
        items.append(item)
        originalItems.append(item)
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removed = items.remove(at: index)
        if let origIdx = originalItems.firstIndex(where: { $0.id == removed.id }) {
            originalItems.remove(at: origIdx)
        }

        guard !items.isEmpty else {
            currentIndex = nil
            return
        }
        if let cur = currentIndex {
            if index < cur {
                currentIndex = cur - 1
            } else if index == cur {
                currentIndex = min(cur, items.count - 1)
            }
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        let activeId = currentItem?.id
        var updated = items
        let moving = source.sorted().map { updated[$0] }
        for idx in source.sorted(by: >) {
            updated.remove(at: idx)
        }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        let clampedDest = min(max(0, adjustedDest), updated.count)
        updated.insert(contentsOf: moving, at: clampedDest)
        items = updated

        if !isShuffled {
            originalItems = items
        }
        if let activeId {
            currentIndex = items.firstIndex(where: { $0.id == activeId })
        }
    }

    func advanceToNext() -> VideoItem? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one, let current = currentItem {
            return current
        }

        guard let cur = currentIndex else {
            currentIndex = 0
            return items.first
        }

        if cur + 1 < items.count {
            currentIndex = cur + 1
            return items[cur + 1]
        } else if repeatMode == .all {
            currentIndex = 0
            return items.first
        }
        return nil
    }

    func previousAction(currentPlaybackTime: TimeInterval) -> QueuePreviousAction {
        guard !items.isEmpty else { return .none }
        if currentPlaybackTime > 3.0 {
            return .restartCurrent
        }

        guard let cur = currentIndex else { return .none }
        if cur > 0 {
            currentIndex = cur - 1
            return .playPrevious(items[cur - 1])
        } else if repeatMode == .all {
            let last = items.count - 1
            currentIndex = last
            return .playPrevious(items[last])
        } else {
            return .restartCurrent
        }
    }

    private func applyShuffleStateChange() {
        let activeItem = currentItem
        if isShuffled {
            guard let activeItem else {
                items.shuffle()
                return
            }
            var rest = originalItems.filter { $0.id != activeItem.id }
            rest.shuffle()
            items = [activeItem] + rest
            currentIndex = 0
        } else {
            items = originalItems
            if let activeItem {
                currentIndex = items.firstIndex(where: { $0.id == activeItem.id })
            }
        }
    }
}
