import AppKit
import ScreenCaptureKit

enum RecorderState {
    case idle
    case configuring
    case starting
    case recording(ActiveRecording)
    case stopping
}

struct ActiveRecording {
    let options: RecordingOptions
    let startedAt: Date
    let stream: SCStream
    let writer: MovieWriter
    let sink: StreamSink
}

@MainActor
final class Recorder: NSObject, SCStreamDelegate {
    private(set) var state: RecorderState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((RecorderState) -> Void)?

    var isMuted: Bool {
        get { if case .recording(let r) = state { r.writer.isMuted } else { false } }
        set { if case .recording(let r) = state { r.writer.isMuted = newValue } }
    }

    func beginConfiguring() {
        guard case .idle = state else { return }
        state = .configuring
    }

    func cancelConfiguring() {
        guard case .configuring = state else { return }
        state = .idle
    }

    func start(_ options: RecordingOptions, excludingWindows excluded: Set<CGWindowID>) {
        guard case .configuring = state else { return }
        state = .starting
        Task {
            var writer: MovieWriter?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == options.target.displayID }),
                      let screen = NSScreen.screen(for: display.displayID) else { throw RecorderError.noDisplay }

                let config = SCStreamConfiguration()
                let size: CGSize
                switch options.target {
                case .display:
                    size = CGSize(width: display.width, height: display.height)
                case .area(_, let rect):
                    config.sourceRect = rect
                    size = rect.size
                }
                let scale = screen.backingScaleFactor
                config.width = Int(size.width * scale) & ~1
                config.height = Int(size.height * scale) & ~1
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = true
                config.capturesAudio = false
                config.captureMicrophone = options.micID != nil
                config.microphoneCaptureDeviceID = options.micID

                let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains($0.windowID) })
                let w = try MovieWriter(url: try Self.newRecordingURL(),
                                        pixelSize: CGSize(width: config.width, height: config.height),
                                        audioChannels: options.micID.map { CaptureDevices.channelCount(microphoneID: $0) })
                writer = w
                let sink = StreamSink(writer: w)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: w.queue)
                if options.micID != nil {
                    try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: w.queue)
                }
                try await stream.startCapture()
                state = .recording(ActiveRecording(options: options, startedAt: Date(), stream: stream, writer: w, sink: sink))
            } catch {
                writer?.cancel()
                fail(error)
            }
        }
    }

    func stop() {
        guard case .recording(let r) = state else { return }
        state = .stopping
        Task {
            do {
                try await r.stream.stopCapture()
            } catch {
                NSLog("stopCapture failed: \(error)")
            }
            await finish(r, interruption: nil)
        }
    }

    private func finish(_ r: ActiveRecording, interruption: Error?) async {
        state = .stopping
        do {
            let url = try await r.writer.finish()
            state = .idle
            await PreviewWindow.show(.recording(url, interruption: interruption?.localizedDescription))
        } catch {
            r.writer.cancel()
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        state = .idle
        let alert = NSAlert(error: error)
        alert.messageText = "Recording failed"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    private static func newRecordingURL() throws -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screengrab")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Recording \(timestamp()).mov")
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard case .recording(let r) = state else { return }
            await finish(r, interruption: error)
        }
    }
}

final class StreamSink: NSObject, SCStreamOutput {
    private let writer: MovieWriter

    init(writer: MovieWriter) { self.writer = writer }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer) else { return }
        switch type {
        case .screen:
            guard buffer.frameStatus == .complete else { return }
            writer.append(video: buffer)
        case .microphone:
            writer.append(audio: buffer)
        default:
            break
        }
    }
}

extension CMSampleBuffer {
    /// Only `.complete` frames carry new content; `.idle` ones repeat the last frame.
    var frameStatus: SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}

enum RecorderError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "No display available to record." }
}
