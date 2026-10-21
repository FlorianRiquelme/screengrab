import AppKit
@preconcurrency import AVFoundation
import AVKit

/// Validated media and its compressed-sample frame index, loaded away from AppKit.
struct RecordingSource: @unchecked Sendable {
    struct Audio {
        let track: AVAssetTrack
        let sampleRate: Double
        let channels: Int
        let range: CMTimeRange
    }

    let url: URL
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: [Audio]
    let frames: RecordingFrames
    let transform: CGAffineTransform
    let pixelSize: CGSize
    let encodedWidth: Int
    let encodedHeight: Int
    let videoTimeScale: CMTimeScale

    static func load(_ url: URL) async throws -> RecordingSource {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration > .zero, try await asset.load(.isReadable),
              let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingMediaError.invalidMedia
        }
        let (naturalSize, transform, formats, scale, videoRange) = try await video.load(
            .naturalSize, .preferredTransform, .formatDescriptions, .naturalTimeScale, .timeRange)
        guard let format = formats.first else { throw RecordingMediaError.invalidMedia }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        guard dimensions.width > 0, dimensions.height > 0, scale > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw RecordingMediaError.invalidMedia
        }
        var audio: [Audio] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let (formats, range) = try await track.load(.formatDescriptions, .timeRange)
            guard let format = formats.first,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                  description.pointee.mSampleRate > 0, description.pointee.mChannelsPerFrame > 0 else {
                throw RecordingMediaError.invalidMedia
            }
            audio.append(Audio(track: track, sampleRate: description.pointee.mSampleRate,
                               channels: Int(description.pointee.mChannelsPerFrame), range: range))
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingMediaError.cannotRead }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecordingMediaError.cannotRead }
        defer { reader.cancelReading() }
        var samples: [RecordingFrames.Frame] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                let offset = CMSampleBufferGetOutputPresentationTimeStamp(buffer) - CMSampleBufferGetPresentationTimeStamp(buffer)
                for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                    var timing = CMSampleTimingInfo()
                    guard CMSampleBufferGetSampleTimingInfo(buffer, at: index, timingInfoOut: &timing) == noErr else {
                        throw RecordingMediaError.cannotRead
                    }
                    let start = timing.presentationTimeStamp + offset
                    let end = timing.duration.isNumeric && timing.duration > .zero ? start + timing.duration : CMTime.invalid
                    samples.append(.init(start: start, end: end))
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? RecordingMediaError.cannotRead }
        if let last = samples.indices.max(by: { samples[$0].start < samples[$1].start }),
           !samples[last].end.isNumeric {
            samples[last] = .init(start: samples[last].start, end: min(duration, videoRange.end))
        }
        let frames = try RecordingFrames(duration: duration, samples: samples)
        try Task.checkCancellation()
        return RecordingSource(url: url, asset: asset, video: video, audio: audio, frames: frames,
                               transform: transform, pixelSize: bounds.size,
                               encodedWidth: Int(dimensions.width), encodedHeight: Int(dimensions.height),
                               videoTimeScale: scale)
    }
}

/// Owns one recording's playback, edit history, and accepted output.
@MainActor
final class RecordingPreview {
    private enum Lifecycle {
        case ready
        case exporting(UUID, Task<RecordingExport.Output, Error>)
        case closed
    }

    private struct Seek {
        let time: CMTime
        let plays: Bool
    }

    let mediaView: AVPlayerView
    let timelineView: RecordingTimeline
    let pixelSize: CGSize
    var onChange: (() -> Void)?

    private let source: RecordingSource
    private let player: AVPlayer
    private let item: AVPlayerItem
    private var history: RecordingEditHistory
    private var lifecycle = Lifecycle.ready
    private var cachedOutput: (edit: RecordingEdit, url: URL)?
    private var playhead: CMTime = .zero
    private var pendingSeek: Seek?
    private var seeking = false
    private var seekGeneration = 0
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var thumbnails: Task<Void, Never>?
    private let imageGenerator: AVAssetImageGenerator

    var isExporting: Bool {
        if case .exporting = lifecycle { return true }
        return false
    }

    private var isReady: Bool {
        if case .ready = lifecycle { return true }
        return false
    }

    var canToggleAudio: Bool { isReady && !source.audio.isEmpty }
    var removesAudio: Bool { history.current.removesAudio }

    static func open(_ sourceURL: URL) async throws -> RecordingPreview {
        let loading = Task.detached(priority: .userInitiated) { try await RecordingSource.load(sourceURL) }
        let source = try await withTaskCancellationHandler {
            try await loading.value
        } onCancel: {
            loading.cancel()
        }
        try Task.checkCancellation()
        return RecordingPreview(source)
    }

    private init(_ source: RecordingSource) {
        self.source = source
        pixelSize = source.pixelSize
        history = RecordingEditHistory(RecordingEdit(retained: CMTimeRange(start: .zero, duration: source.frames.duration), removesAudio: false))
        item = AVPlayerItem(asset: source.asset)
        player = AVPlayer(playerItem: item)
        mediaView = AVPlayerView()
        timelineView = RecordingTimeline()
        imageGenerator = AVAssetImageGenerator(asset: source.asset)
        mediaView.player = player
        mediaView.controlsStyle = .minimal
        mediaView.showsSharingServiceButton = false
        mediaView.showsFullScreenToggleButton = false
        mediaView.allowsPictureInPicturePlayback = false
        player.actionAtItemEnd = .pause
        item.forwardPlaybackEndTime = source.frames.duration
        timelineView.onInput = { [weak self] input in self?.receive(input) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isReady, !self.seeking, self.pendingSeek == nil else { return }
                self.playhead = time
                self.display()
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.player.rate != 0 {
                    if !self.isReady {
                        self.player.pause()
                    } else {
                        let time = self.player.currentTime(), range = self.history.current.retained
                        if time < range.start || time >= range.end {
                            self.requestSeek(range.start, plays: true)
                        }
                    }
                }
                self.display()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isReady else { return }
                self.player.pause()
                self.playhead = self.history.current.retained.end
                self.display()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, let window = self.mediaView.window, event.window === window,
                      window.isKeyWindow, !Tips.isShowing else { return false }
                return self.handleKey(event)
            }
            return consumed ? nil : event
        }
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 160, height: 100)
        startThumbnails()
        display()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard !Tips.isShowing else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", flags == .command || flags == [.command, .shift] {
            guard isReady else { return true }
            player.pause()
            finishAdjustment()
            if flags == .command { history.undo() } else { history.redo() }
            applyEdit(preview: .start)
            return true
        }
        guard flags.isEmpty else { return false }
        let arrow = event.keyCode == 123 || event.keyCode == 124
        let space = event.keyCode == 49
        let mark = key == "i" || key == "o"
        guard arrow || space || mark else { return false }
        guard isReady else { return true }
        if let focused = mediaView.window?.firstResponder as? NSView,
           focused === timelineView || focused.isDescendant(of: timelineView),
           space || (arrow && focused !== timelineView) {
            return false
        }
        if space {
            togglePlayback()
        } else if arrow {
            finishAdjustment()
            requestSeek(source.frames.step(from: navigationTime, by: event.keyCode == 123 ? -1 : 1, within: history.current.retained))
        } else {
            finishAdjustment()
            let edit = key == "i"
                ? source.frames.settingStart(source.frames.frames[source.frames.index(at: displayedTime)].start, in: history.current)
                : source.frames.markingOut(at: displayedTime, in: history.current)
            history.set(edit)
            applyEdit(preview: key == "i" ? .start : .end)
        }
        return true
    }

    func toggleRemoveAudio() {
        guard canToggleAudio else { return }
        finishAdjustment()
        history.set(RecordingEdit(retained: history.current.retained, removesAudio: !history.current.removesAudio))
        applyEdit()
    }

    func prepareOutput(progress: @escaping (Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard isReady else { throw isExporting ? RecordingMediaError.busy : RecordingMediaError.closed }
        finishAdjustment()
        let edit = history.current
        let original = RecordingEdit(retained: CMTimeRange(start: .zero, duration: source.frames.duration), removesAudio: false)
        if edit == original { progress(1); return source.url }
        if let cachedOutput, cachedOutput.edit == edit { progress(1); return cachedOutput.url }
        player.pause()
        invalidateSeeks()
        let identifier = UUID(), source = self.source
        let report: @Sendable (Double) -> Void = { [weak self] value in
            guard let preview = self else { return }
            Task { @MainActor [weak preview] in
                guard let preview, case .exporting(let current, _) = preview.lifecycle, current == identifier else { return }
                progress(min(1, max(0, value)))
            }
        }
        let task = Task.detached(priority: .userInitiated) {
            try await RecordingExport.render(source: source, edit: edit, progress: report)
        }
        lifecycle = .exporting(identifier, task)
        display()
        onChange?()
        progress(0)
        do {
            let output = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard case .exporting(let current, _) = lifecycle, current == identifier else { throw CancellationError() }
            let url = output.accept()
            cachedOutput = (edit, url)
            lifecycle = .ready
            display()
            onChange?()
            progress(1)
            return url
        } catch {
            if case .exporting(let current, _) = lifecycle, current == identifier {
                lifecycle = .ready
                display()
                onChange?()
            }
            throw error
        }
    }

    func close() {
        if case .closed = lifecycle { return }
        let previous = lifecycle
        lifecycle = .closed
        if case .exporting(_, let task) = previous { task.cancel() }
        thumbnails?.cancel()
        thumbnails = nil
        imageGenerator.cancelAllCGImageGeneration()
        invalidateSeeks()
        player.pause()
        rateObservation?.invalidate()
        rateObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        timelineView.onInput = nil
        display()
        mediaView.player = nil
        player.replaceCurrentItem(with: nil)
        onChange?()
        onChange = nil
    }

    private var displayedTime: CMTime { player.currentTime() }

    private var navigationTime: CMTime {
        seeking || pendingSeek != nil ? playhead : displayedTime
    }

    private func finishAdjustment() {
        let wasAdjusting = history.isAdjusting
        history.finish()
        if wasAdjusting {
            display(enabled: false)
            display()
        }
    }

    private func receive(_ input: RecordingTimeline.Input) {
        guard isReady else { return }
        switch input {
        case .begin:
            player.pause()
            history.begin()
        case .adjust(let edge, let time):
            adjust(edge, to: time)
        case .end:
            history.finish()
            display()
        case .cancel:
            history.cancel()
            applyEdit()
        case .scrub(let time):
            history.finish()
            requestSeek(source.frames.frames[source.frames.index(at: time)].start)
        case .step(let edge, let amount):
            let edit = edge == .start
                ? source.frames.steppingStart(by: amount, in: history.current)
                : source.frames.steppingEnd(by: amount, in: history.current)
            history.set(edit)
            applyEdit(preview: edge)
        case .togglePlayback:
            togglePlayback()
        }
    }

    private func adjust(_ edge: RecordingTimeline.Edge, to time: CMTime) {
        let edit = edge == .start ? source.frames.settingStart(time, in: history.current) : source.frames.settingEnd(time, in: history.current)
        history.set(edit)
        applyEdit(preview: edge)
    }

    private func applyEdit(preview edge: RecordingTimeline.Edge? = nil) {
        let edit = history.current
        item.forwardPlaybackEndTime = edit.retained.end
        item.reversePlaybackEndTime = edit.retained.start
        player.isMuted = edit.removesAudio
        if let edge {
            let time = edge == .start ? edit.retained.start : source.frames.frames[source.frames.lastIndex(in: edit.retained)].start
            requestSeek(time)
        } else {
            display()
        }
        onChange?()
    }

    private func togglePlayback() {
        guard isReady else { return }
        finishAdjustment()
        if player.rate != 0 {
            player.pause()
            display()
            return
        }
        let range = history.current.retained, time = navigationTime
        requestSeek(time < range.start || time >= range.end ? range.start : time, plays: true)
    }

    private func requestSeek(_ time: CMTime, plays: Bool = false) {
        guard isReady else { return }
        player.pause()
        let target = min(source.frames.frames.last!.start, max(.zero, time))
        pendingSeek = Seek(time: target, plays: plays)
        playhead = target
        display()
        pumpSeek()
    }

    private func pumpSeek() {
        guard !seeking, let seek = pendingSeek, isReady else { return }
        pendingSeek = nil
        seeking = true
        let generation = seekGeneration
        player.seek(to: seek.time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation, self.isReady else { return }
                self.seeking = false
                if self.pendingSeek != nil {
                    self.pumpSeek()
                } else {
                    self.playhead = self.player.currentTime()
                    if finished && seek.plays { self.player.play() }
                    self.display()
                }
            }
        }
    }

    private func invalidateSeeks() {
        seekGeneration += 1
        pendingSeek = nil
        seeking = false
        item.cancelPendingSeeks()
    }

    private func display(enabled: Bool? = nil) {
        timelineView.display(.init(duration: source.frames.duration, retained: history.current.retained,
                                   playhead: playhead, isPlaying: player.rate != 0,
                                   removesAudio: history.current.removesAudio, isEnabled: enabled ?? isReady))
    }

    private func startThumbnails() {
        let generator = imageGenerator, frames = source.frames
        thumbnails = Task(priority: .utility) { [weak self] in
            do {
                var images: [CGImage] = []
                let count = min(10, frames.frames.count)
                images.reserveCapacity(count)
                try await withTaskCancellationHandler {
                    for index in 0..<count {
                        try Task.checkCancellation()
                        let time = count == 1 ? CMTime.zero : CMTimeMultiplyByRatio(frames.duration, multiplier: Int32(index), divisor: Int32(count - 1))
                        let image = try await generator.image(at: frames.frames[frames.index(at: time)].start)
                        images.append(image.image)
                    }
                } onCancel: {
                    generator.cancelAllCGImageGeneration()
                }
                try Task.checkCancellation()
                guard let self, self.isReady || self.isExporting else { return }
                self.timelineView.setThumbnails(images.map { NSImage(cgImage: $0, size: .zero) })
            } catch {
            }
        }
    }
}
