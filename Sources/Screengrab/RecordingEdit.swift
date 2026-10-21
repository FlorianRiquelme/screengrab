@preconcurrency import AVFoundation

/// Actual source sample boundaries shared by editing and playback.
struct RecordingFrames: Sendable {
    struct Frame: Sendable {
        let start: CMTime
        let end: CMTime
    }

    let duration: CMTime
    let frames: [Frame]

    init(duration: CMTime, samples: [Frame]) throws {
        guard duration.isNumeric, duration > .zero else { throw RecordingMediaError.invalidMedia }
        let sorted = samples.filter { $0.start.isNumeric && $0.start >= .zero && $0.start < duration }
            .sorted { $0.start < $1.start }
        var unique: [Frame] = []
        unique.reserveCapacity(sorted.count)
        for sample in sorted {
            if let last = unique.last, last.start == sample.start {
                if sample.end.isNumeric && (!last.end.isNumeric || sample.end > last.end) {
                    unique[unique.count - 1] = sample
                }
            } else {
                unique.append(sample)
            }
        }
        guard !unique.isEmpty else { throw RecordingMediaError.invalidMedia }
        frames = unique.enumerated().map { index, sample in
            let next = index + 1 < unique.count ? unique[index + 1].start : duration
            let end = sample.end.isNumeric && sample.end > sample.start ? min(sample.end, next) : next
            return Frame(start: sample.start, end: min(end, duration))
        }
        self.duration = duration
    }

    func index(at time: CMTime) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    func nearestStart(to time: CMTime) -> Int {
        let before = index(at: time), after = min(before + 1, frames.count - 1)
        return abs((time - frames[before].start).seconds) <= abs((frames[after].start - time).seconds) ? before : after
    }

    func nearestEnd(to time: CMTime) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].end < time { low = middle + 1 } else { high = middle }
        }
        let after = min(low, frames.count - 1), before = max(0, after - 1)
        return abs((time - frames[before].end).seconds) <= abs((frames[after].end - time).seconds) ? before : after
    }

    func lastIndex(in range: CMTimeRange) -> Int {
        let candidate = index(at: range.end)
        return frames[candidate].start < range.end ? candidate : max(0, candidate - 1)
    }

    func step(from time: CMTime, by amount: Int, within range: CMTimeRange) -> CMTime {
        let first = index(at: range.start), last = lastIndex(in: range)
        return frames[min(last, max(first, index(at: time) + amount))].start
    }

    func settingStart(_ time: CMTime, in edit: RecordingEdit) -> RecordingEdit {
        let index = min(nearestStart(to: time), lastIndex(in: edit.retained))
        let frameStart = frames[index].start
        let start = abs(time.seconds) < abs((time - frameStart).seconds) ? CMTime.zero : frameStart
        return RecordingEdit(retained: CMTimeRange(start: start, end: edit.retained.end), removesAudio: edit.removesAudio)
    }

    func settingEnd(_ time: CMTime, in edit: RecordingEdit) -> RecordingEdit {
        let index = max(nearestEnd(to: time), self.index(at: edit.retained.start))
        let frameEnd = frames[index].end
        let end = abs((duration - time).seconds) < abs((frameEnd - time).seconds) ? duration : frameEnd
        return RecordingEdit(retained: CMTimeRange(start: edit.retained.start, end: end), removesAudio: edit.removesAudio)
    }

    func markingOut(at time: CMTime, in edit: RecordingEdit) -> RecordingEdit {
        settingEnd(frames[index(at: time)].end, in: edit)
    }

    func steppingStart(by amount: Int, in edit: RecordingEdit) -> RecordingEdit {
        let leading = frames[0].start > .zero ? 1 : 0
        let current = leading == 1 && edit.retained.start == .zero ? 0 : index(at: edit.retained.start) + leading
        let next = min(frames.count - 1 + leading, max(0, current + amount))
        return settingStart(next < leading ? .zero : frames[next - leading].start, in: edit)
    }

    func steppingEnd(by amount: Int, in edit: RecordingEdit) -> RecordingEdit {
        let trailing = frames[frames.count - 1].end < duration ? 1 : 0
        let current = trailing == 1 && edit.retained.end == duration ? frames.count : nearestEnd(to: edit.retained.end)
        let next = min(frames.count - 1 + trailing, max(0, current + amount))
        return settingEnd(next == frames.count ? duration : frames[next].end, in: edit)
    }
}

/// A document edit excludes playback position and output state.
struct RecordingEdit: Equatable, Sendable {
    let retained: CMTimeRange
    let removesAudio: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.retained.start == rhs.retained.start && lhs.retained.duration == rhs.retained.duration && lhs.removesAudio == rhs.removesAudio
    }
}

/// Gestures replace the live edit but enter history only once.
struct RecordingEditHistory {
    private(set) var current: RecordingEdit
    private var undoStack: [RecordingEdit] = []
    private var redoStack: [RecordingEdit] = []
    private var gesture: RecordingEdit?

    init(_ edit: RecordingEdit) { current = edit }

    var isAdjusting: Bool { gesture != nil }

    mutating func begin() {
        finish()
        gesture = current
    }

    mutating func set(_ edit: RecordingEdit) {
        guard edit != current else { return }
        if gesture == nil {
            undoStack.append(current)
            redoStack.removeAll()
        }
        current = edit
    }

    mutating func finish() {
        guard let initial = gesture else { return }
        gesture = nil
        if initial != current {
            undoStack.append(initial)
            redoStack.removeAll()
        }
    }

    mutating func cancel() {
        if let initial = gesture { current = initial }
        gesture = nil
    }

    mutating func undo() {
        finish()
        guard let edit = undoStack.popLast() else { return }
        redoStack.append(current)
        current = edit
    }

    mutating func redo() {
        finish()
        guard let edit = redoStack.popLast() else { return }
        undoStack.append(current)
        current = edit
    }
}

enum RecordingMediaError: LocalizedError {
    case invalidMedia
    case cannotRead
    case cannotWrite
    case closed
    case busy

    var errorDescription: String? {
        switch self {
        case .invalidMedia: "This recording has no readable video frames or valid duration."
        case .cannotRead: "The recording could not be read."
        case .cannotWrite: "The edited recording could not be written."
        case .closed: "The recording preview is closed."
        case .busy: "The recording is already being exported."
        }
    }
}
