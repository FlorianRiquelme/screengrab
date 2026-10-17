@preconcurrency import AVFoundation
import os

/// Writes H.264 video and AAC audio sample buffers to a QuickTime file.
/// `append` calls must be serialized; use `queue` as the capture sample handler queue.
final class MovieWriter: @unchecked Sendable {
    let queue = DispatchQueue(label: "screengrab.writer")

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private let muted = OSAllocatedUnfairLock(initialState: false)

    var isMuted: Bool {
        get { muted.withLock { $0 } }
        set { muted.withLock { $0 = newValue } }
    }

    var url: URL { writer.outputURL }

    init(url: URL, pixelSize: CGSize, audioChannels: Int?) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        if let audioChannels {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }

        guard writer.startWriting() else { throw writer.error ?? MovieWriterError.failed }
    }

    /// Returns false when the frame was dropped because the encoder was not ready.
    @discardableResult
    func append(video buffer: CMSampleBuffer) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        guard video.isReadyForMoreMediaData else { return false }
        return video.append(buffer)
    }

    @discardableResult
    func append(audio buffer: CMSampleBuffer) -> Bool {
        guard let audio, let start = sessionStart,
              CMSampleBufferGetPresentationTimeStamp(buffer) >= start,
              audio.isReadyForMoreMediaData else { return false }
        if isMuted, let data = CMSampleBufferGetDataBuffer(buffer) {
            // Silence keeps the AAC track continuous; dropping buffers would leave a gap players handle badly.
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                       dataLength: CMBlockBufferGetDataLength(data))
        }
        return audio.append(buffer)
    }

    func cancel() {
        queue.async {
            if self.writer.status == .writing { self.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: self.writer.outputURL)
        }
    }

    func finish() async throws -> URL {
        let started = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            queue.async {
                guard self.sessionStart != nil else {
                    self.writer.cancelWriting()
                    return done.resume(returning: false)
                }
                self.video.markAsFinished()
                self.audio?.markAsFinished()
                done.resume(returning: true)
            }
        }
        guard started else { throw MovieWriterError.noFrames }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MovieWriterError.failed }
        return writer.outputURL
    }
}

enum MovieWriterError: LocalizedError {
    case noFrames
    case failed

    var errorDescription: String? {
        switch self {
        case .noFrames: "The recording contained no video frames."
        case .failed: "The movie file could not be written."
        }
    }
}
