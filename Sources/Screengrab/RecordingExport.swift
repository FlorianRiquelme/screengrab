@preconcurrency import AVFoundation
import os

/// Decodes selected samples and owns every output file until the preview accepts it.
enum RecordingExport {
    final class Output: @unchecked Sendable {
        let url: URL
        private let accepted = OSAllocatedUnfairLock(initialState: false)

        init(_ url: URL) { self.url = url }

        func accept() -> URL {
            accepted.withLock { $0 = true }
            return url
        }

        deinit {
            if !accepted.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func render(source: RecordingSource, edit: RecordingEdit,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Output {
        let operation = try Operation(source: source, edit: edit, progress: progress)
        let output = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.run()
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    private final class Stream {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        var finished = false

        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, isVideo: Bool) {
            self.output = output
            self.input = input
            self.isVideo = isVideo
        }
    }

    private final class Operation: @unchecked Sendable {
        private enum State { case idle, running, finishing, cancelled, ended }
        private let queue = DispatchQueue(label: "screengrab.recording-export", qos: .userInitiated)
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let source: RecordingSource
        private let edit: RecordingEdit
        private let staged: URL
        private let published: URL
        private let progress: @Sendable (Double) -> Void
        private var streams: [Stream] = []
        private var state = State.idle
        private var continuation: CheckedContinuation<Output, Error>?
        private var lastProgress = 0.0
        private let cancellation = OSAllocatedUnfairLock(initialState: false)
        private var wroteVideo = false

        init(source: RecordingSource, edit: RecordingEdit, progress: @escaping @Sendable (Double) -> Void) throws {
            self.source = source
            self.edit = edit
            self.progress = progress
            let directory = source.url.deletingLastPathComponent()
            let identifier = UUID().uuidString
            staged = directory.appendingPathComponent(".screengrab-\(identifier).mov")
            published = directory.appendingPathComponent("\(source.url.deletingPathExtension().lastPathComponent) Edited \(identifier).mov")
            reader = try AVAssetReader(asset: source.asset)
            writer = try AVAssetWriter(outputURL: staged, fileType: .mov)
            writer.movieTimeScale = max(source.videoTimeScale, edit.retained.duration.timescale)
            reader.timeRange = edit.retained

            let videoOutput = AVAssetReaderTrackOutput(track: source.video, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            videoOutput.alwaysCopiesSampleData = false
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: source.encodedWidth,
                AVVideoHeightKey: source.encodedHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
            ])
            videoInput.transform = source.transform
            videoInput.mediaTimeScale = source.videoTimeScale
            guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw RecordingMediaError.cannotWrite }
            reader.add(videoOutput)
            writer.add(videoInput)
            streams.append(Stream(output: videoOutput, input: videoInput, isVideo: true))

            if !edit.removesAudio {
                for audio in source.audio where CMTimeRangeGetIntersection(audio.range, otherRange: edit.retained).duration > .zero {
                    let output = AVAssetReaderTrackOutput(track: audio.track, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                    ])
                    output.alwaysCopiesSampleData = false
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: audio.sampleRate,
                        AVNumberOfChannelsKey: audio.channels,
                        AVEncoderBitRateKey: min(320_000, max(64_000, audio.channels * 96_000)),
                    ])
                    guard reader.canAdd(output), writer.canAdd(input) else { throw RecordingMediaError.cannotWrite }
                    reader.add(output)
                    writer.add(input)
                    streams.append(Stream(output: output, input: input, isVideo: false))
                }
            }
        }

        deinit { try? FileManager.default.removeItem(at: staged) }

        func run() async throws -> Output {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    guard !self.cancellation.withLock({ $0 }) else {
                        self.fail(CancellationError())
                        return
                    }
                    guard self.writer.startWriting() else {
                        self.fail(self.writer.error ?? RecordingMediaError.cannotWrite)
                        return
                    }
                    self.writer.startSession(atSourceTime: .zero)
                    guard self.reader.startReading() else {
                        self.fail(self.reader.error ?? RecordingMediaError.cannotRead)
                        return
                    }
                    self.state = .running
                    self.progress(0)
                    for stream in self.streams {
                        stream.input.requestMediaDataWhenReady(on: self.queue) { [weak operation = self, weak stream] in
                            guard let operation, let stream else { return }
                            operation.drain(stream)
                        }
                    }
                }
            }
        }

        func cancel() {
            cancellation.withLock { $0 = true }
            queue.async {
                guard self.state != .ended else { return }
                if self.state == .idle {
                    self.state = .cancelled
                } else {
                    self.fail(CancellationError())
                }
            }
        }

        private func drain(_ stream: Stream) {
            guard state == .running, !stream.finished else { return }
            do {
                while stream.input.isReadyForMoreMediaData {
                    if cancellation.withLock({ $0 }) { throw CancellationError() }
                    guard let sample = stream.output.copyNextSampleBuffer() else {
                        if reader.status == .failed { throw reader.error ?? RecordingMediaError.cannotRead }
                        stream.finished = true
                        stream.input.markAsFinished()
                        if streams.allSatisfy(\.finished) { finish() }
                        return
                    }
                    let mapped = try autoreleasepool { try map(sample, video: stream.isVideo) }
                    guard let mapped else { continue }
                    guard stream.input.append(mapped) else { throw writer.error ?? RecordingMediaError.cannotWrite }
                    if stream.isVideo {
                        wroteVideo = true
                        let value = min(0.99, max(0, (CMSampleBufferGetPresentationTimeStamp(sample) - edit.retained.start).seconds / edit.retained.duration.seconds))
                        if value - lastProgress >= 0.01 {
                            lastProgress = value
                            progress(value)
                        }
                    }
                }
            } catch {
                fail(error)
            }
        }

        private func map(_ sample: CMSampleBuffer, video: Bool) throws -> CMSampleBuffer? {
            let start = edit.retained.start, end = edit.retained.end
            var buffer = sample
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if video {
                guard pts >= start, pts < end else { return nil }
            } else {
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                      description.pointee.mSampleRate > 0 else { throw RecordingMediaError.cannotRead }
                let scale = CMTimeScale(description.pointee.mSampleRate.rounded())
                let count = CMSampleBufferGetNumSamples(buffer)
                let first = max(0, min(count, Int(CMTimeConvertScale(start - pts, timescale: scale, method: .roundTowardPositiveInfinity).value)))
                let last = max(0, min(count, Int(CMTimeConvertScale(end - pts, timescale: scale, method: .roundTowardNegativeInfinity).value)))
                guard last > first else { return nil }
                if first != 0 || last != count {
                    var cropped: CMSampleBuffer?
                    guard CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                        sampleRange: CFRange(location: first, length: last - first), sampleBufferOut: &cropped) == noErr,
                          let cropped else { throw RecordingMediaError.cannotRead }
                    buffer = cropped
                }
            }
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timing) == noErr else {
                throw RecordingMediaError.cannotRead
            }
            let sourceTime = timing.presentationTimeStamp
            timing.presentationTimeStamp = sourceTime - start
            timing.decodeTimeStamp = .invalid
            if video {
                let frame = source.frames.frames[source.frames.index(at: sourceTime)]
                timing.duration = min(frame.end, end) - sourceTime
            }
            var mapped: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &mapped) == noErr,
                  let mapped else { throw RecordingMediaError.cannotWrite }
            return mapped
        }

        private func finish() {
            guard wroteVideo else { fail(RecordingMediaError.invalidMedia); return }
            state = .finishing
            writer.endSession(atSourceTime: edit.retained.duration)
            writer.finishWriting {
                self.queue.async {
                    guard self.state == .finishing else { return }
                    guard self.writer.status == .completed else {
                        self.fail(self.writer.error ?? RecordingMediaError.cannotWrite)
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: self.staged, to: self.published)
                        let output = Output(self.published)
                        self.state = .ended
                        self.progress(1)
                        self.continuation?.resume(returning: output)
                        self.continuation = nil
                    } catch {
                        self.fail(error)
                    }
                }
            }
        }

        private func fail(_ error: Error) {
            guard state != .ended else { return }
            state = .ended
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: staged)
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
