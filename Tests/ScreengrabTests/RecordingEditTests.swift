@preconcurrency import AVFoundation
import Testing
@testable import Screengrab

@Suite struct RecordingEditTests {
    @Test func variableFrameRateStepsNeverEnterExclusiveEnd() throws {
        let frames = try sourceFrames()
        let retained = CMTimeRange(start: time(40), end: time(310))
        #expect(frames.step(from: time(40), by: 1, within: retained) == time(110))
        #expect(frames.step(from: time(110), by: 1, within: retained) == time(110))
        #expect(frames.step(from: time(110), by: -1, within: retained) == time(40))
        #expect(frames.step(from: time(40), by: -1, within: retained) == time(40))
    }

    @Test func markOutIncludesDisplayedFrameButNotFollowingFrame() throws {
        let frames = try sourceFrames()
        let edit = frames.markingOut(at: time(180), in: original())
        #expect(edit.retained.start == .zero)
        #expect(edit.retained.end == time(310))
        #expect(frames.frames[frames.lastIndex(in: edit.retained)].start == time(110))
    }

    @Test func crossingHandlesRetainsOneActualFrame() throws {
        let frames = try sourceFrames()
        let selected = RecordingEdit(retained: CMTimeRange(start: time(110), end: time(310)), removesAudio: true)
        let start = frames.settingStart(time(650), in: selected)
        let end = frames.settingEnd(.zero, in: selected)
        #expect(start == selected)
        #expect(end == selected)
    }

    @Test func indexUsesPresentationOrderAndSampleDurations() throws {
        let frames = try RecordingFrames(duration: time(700), samples: [
            .init(start: time(110), end: time(310)),
            .init(start: .zero, end: time(40)),
            .init(start: time(310), end: time(500)),
            .init(start: time(40), end: .invalid),
        ])
        #expect(frames.frames.map(\.start) == [time(0), time(40), time(110), time(310)])
        #expect(frames.frames[1].end == time(110))
        #expect(frames.markingOut(at: time(600), in: original()).retained.end == time(500))
        #expect(frames.duration == time(700))
    }
    @Test func handlesCanRestoreSourceGapsWithoutInventingFrames() throws {
        let frames = try RecordingFrames(duration: time(700), samples: [
            .init(start: time(40), end: time(110)),
            .init(start: time(110), end: time(310)),
        ])
        let trimmed = RecordingEdit(retained: CMTimeRange(start: time(40), end: time(310)), removesAudio: true)
        let withLeadingGap = frames.steppingStart(by: -1, in: trimmed)
        let full = frames.steppingEnd(by: 1, in: withLeadingGap)
        #expect(full.retained.start == .zero)
        #expect(full.retained.end == time(700))
        #expect(full.removesAudio)
        #expect(frames.steppingEnd(by: -1, in: full).retained.end == time(310))
        #expect(frames.steppingStart(by: 1, in: full).retained.start == time(40))
        #expect(frames.settingEnd(time(700), in: trimmed).retained.end == time(700))
        #expect(frames.settingStart(.zero, in: trimmed).retained.start == .zero)
    }


    @Test func dragAndAudioToggleHaveIndependentUndoAndRedo() throws {
        let frames = try sourceFrames(), initial = original()
        var history = RecordingEditHistory(initial)
        history.begin()
        history.set(frames.settingStart(time(40), in: history.current))
        history.set(frames.settingStart(time(110), in: history.current))
        history.finish()
        let trimmed = history.current
        history.set(RecordingEdit(retained: trimmed.retained, removesAudio: true))
        history.undo()
        #expect(history.current == trimmed)
        history.undo()
        #expect(history.current == initial)
        history.undo()
        #expect(history.current == initial)
        history.redo()
        #expect(history.current == trimmed)
        history.redo()
        #expect(history.current.retained.start == time(110))
        #expect(history.current.removesAudio)
    }

    @Test func cancellingDragPreservesEarlierRedo() throws {
        let frames = try sourceFrames(), initial = original()
        let trimmed = frames.settingStart(time(110), in: initial)
        var history = RecordingEditHistory(initial)
        history.set(trimmed)
        history.undo()
        history.begin()
        history.set(frames.settingEnd(time(310), in: history.current))
        history.cancel()
        #expect(history.current == initial)
        history.redo()
        #expect(history.current == trimmed)
    }

    @Test func undoDuringDragRestoresGestureStartInOneStep() throws {
        let frames = try sourceFrames(), initial = original()
        var history = RecordingEditHistory(initial)
        history.begin()
        history.set(frames.settingStart(time(40), in: history.current))
        history.set(frames.settingStart(time(110), in: history.current))
        history.undo()
        #expect(history.current == initial)
        history.redo()
        #expect(history.current.retained.start == time(110))
    }

    private func sourceFrames() throws -> RecordingFrames {
        try RecordingFrames(duration: time(700), samples: [
            .init(start: time(0), end: time(40)),
            .init(start: time(40), end: time(110)),
            .init(start: time(110), end: time(310)),
            .init(start: time(310), end: time(500)),
        ])
    }

    private func original() -> RecordingEdit {
        RecordingEdit(retained: CMTimeRange(start: .zero, duration: time(700)), removesAudio: false)
    }

    private func time(_ milliseconds: Int64) -> CMTime {
        CMTime(value: milliseconds, timescale: 1_000)
    }
}
