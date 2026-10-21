@preconcurrency import AVFoundation
import Testing
@testable import Screengrab

@Suite struct RecordingSourceTests {
    @Test func frameIndexUsesThePresentedMovieTimeline() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-source-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: true],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecordingMediaError.cannotWrite }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? RecordingMediaError.cannotWrite }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixel: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixel)
            #expect(status == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 2), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? RecordingMediaError.cannotWrite
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? RecordingMediaError.cannotWrite }

        let source = try await RecordingSource.load(url)
        #expect(source.frames.frames.count == 90)
        #expect(source.frames.frames.first?.start == .zero)
        #expect(source.frames.frames[13].start == CMTime(value: 13, timescale: 30))
        #expect(source.frames.frames.last?.end == CMTime(value: 3, timescale: 1))
        let selected = source.frames.markingOut(at: CMTime(value: 13, timescale: 30),
            in: RecordingEdit(retained: CMTimeRange(start: .zero, duration: source.frames.duration), removesAudio: false))
        #expect(selected.retained.end == CMTime(value: 14, timescale: 30))
    }
}
