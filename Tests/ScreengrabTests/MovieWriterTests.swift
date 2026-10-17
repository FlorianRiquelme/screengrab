@preconcurrency import AVFoundation
import Testing
@testable import Screengrab

@Suite struct MovieWriterTests {
    @Test func muteSilencesAudioMidRecording() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 320, height: 240)
        let writer = try MovieWriter(url: url, pixelSize: size, audioChannels: 1)

        let fps = 30, frames = 90, hop = 480  // 10 ms of 48 kHz audio per buffer
        let videoFormat = try videoFormatDescription(size: size)
        let audioFormat = try monoFloatFormatDescription()
        var audioSample = 0
        for i in 0..<frames {
            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            let frame = try videoBuffer(size: size, format: videoFormat, pts: pts)
            while !writer.append(video: frame) { try await Task.sleep(for: .milliseconds(5)) }

            let frameEnd = Double(i + 1) / Double(fps)
            while Double(audioSample) / 48_000 < frameEnd {
                let t = Double(audioSample) / 48_000
                writer.isMuted = t >= 1.0 && t < 2.0
                let buffer = try sineBuffer(format: audioFormat, firstSample: audioSample, count: hop)
                while !writer.append(audio: buffer) { try await Task.sleep(for: .milliseconds(5)) }
                audioSample += hop
            }
        }
        let out = try await writer.finish()

        let asset = AVURLAsset(url: out)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        #expect(videoTracks.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3.0) < 0.2, "duration \(duration)")

        let rms = try await decodedRMS(asset: asset, windows: [0.2...0.8, 1.2...1.8, 2.2...2.8])
        print("duration \(duration)s, rms loud/muted/loud = \(rms)")
        #expect(rms[0] > 0.25, "loud before mute, rms \(rms[0])")
        #expect(rms[1] < 0.01, "silent while muted, rms \(rms[1])")
        #expect(rms[2] > 0.25, "loud after unmute, rms \(rms[2])")
    }
}

private func videoFormatDescription(size: CGSize) throws -> CMVideoFormatDescription {
    try CMVideoFormatDescription(videoCodecType: .init(rawValue: kCVPixelFormatType_32BGRA),
                                 width: Int(size.width), height: Int(size.height))
}

private func videoBuffer(size: CGSize, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else { throw TestError.pixelBuffer(status) }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, Int32(truncatingIfNeeded: Int(pts.seconds * 40)), CVPixelBufferGetDataSize(pixelBuffer))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
}

private func monoFloatFormatDescription() throws -> CMAudioFormatDescription {
    let asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    return try CMAudioFormatDescription(audioStreamBasicDescription: asbd)
}

private func sineBuffer(format: CMAudioFormatDescription, firstSample: Int, count: Int) throws -> CMSampleBuffer {
    var samples = (0..<count).map { Float(0.5 * sin(2 * .pi * 1000 * Double(firstSample + $0) / 48_000)) }
    let byteCount = count * MemoryLayout<Float>.size
    let block = try CMBlockBuffer(length: byteCount)
    try samples.withUnsafeMutableBytes { try block.replaceDataBytes(with: UnsafeRawBufferPointer($0)) }
    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                    presentationTimeStamp: CMTime(value: CMTimeValue(firstSample), timescale: 48_000),
                                    decodeTimeStamp: .invalid)
    return try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: count,
                              sampleTimings: [timing], sampleSizes: [MemoryLayout<Float>.size])
}

private func decodedRMS(asset: AVAsset, windows: [ClosedRange<Double>]) async throws -> [Double] {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TestError.noAudioTrack }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? TestError.reader }

    var sums = [Double](repeating: 0, count: windows.count)
    var counts = [Int](repeating: 0, count: windows.count)
    while let buffer = output.copyNextSampleBuffer() {
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        let data = try buffer.dataBuffer?.dataBytes() ?? Data()
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for (i, sample) in floats.enumerated() {
            let t = start + Double(i) / 48_000
            for (w, window) in windows.enumerated() where window.contains(t) {
                sums[w] += Double(sample * sample)
                counts[w] += 1
            }
        }
    }
    return zip(sums, counts).map { count in count.1 > 0 ? (count.0 / Double(count.1)).squareRoot() : 0 }
}

enum TestError: Error {
    case pixelBuffer(CVReturn)
    case noAudioTrack
    case reader
}
