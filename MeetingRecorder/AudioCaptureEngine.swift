//
//  AudioCaptureEngine.swift
//  MeetingRecorder
//
//  Captures TWO audio sources simultaneously:
//    1. System audio  — the call / everyone else, via ScreenCaptureKit.
//       Captured BEFORE it reaches any Bluetooth or speaker output, so
//       the recording is clean regardless of what output device is active.
//    2. Microphone    — your own voice, via AVAudioEngine.
//       Runs on its own continuous tap, completely independent of the
//       system-audio stream so neither source ever pauses the other.
//
//  WHY two separate temp files?
//  ──────────────────────────────────────────────────────────────────────
//  The naive approach (original version) wrote both sources' buffers into
//  ONE AVAudioFile as they arrived from their respective callbacks.
//  AVAudioFile.write() APPENDS raw frames — it does NOT mix or sum — so
//  the result was interleaved chunks of mic audio and system audio:
//  garbled, roughly double the expected duration.
//
//  This version writes each source to its own hidden temp WAV file
//  (.meeting-<stamp>.mic.wav  /  .meeting-<stamp>.system.wav), then
//  SUMS them sample-by-sample into the final output file when you press
//  Stop.  The shorter track is padded with silence; the sum is soft-clipped
//  to ±1 to prevent digital overs.
//
//  Threading model:
//  ──────────────────────────────────────────────────────────────────────
//  • SCStream audio callbacks arrive on `sampleHandlerQueue` (serial).
//  • AVAudioEngine tap callbacks arrive on an internal engine thread.
//  • Both converge on `writeQueue` (serial) before touching AVAudioFile,
//    so file access is always single-threaded.
//  • Published properties and async methods run on MainActor.
//
//  Author : Ibrahim Sultan
//  Requires: macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine

/// Observable engine that manages the full recording lifecycle:
/// start → capture (mic + system) → stop → mix → save.
///
/// All `@Published` properties are safe to observe from SwiftUI on the main thread.
/// Async `startRecording()` / `stopRecording()` must be called on `@MainActor`
/// (the default when called from a SwiftUI `Task {}`).
@MainActor
final class AudioCaptureEngine: NSObject, ObservableObject {

    // MARK: - Published state for the UI

    /// `true` while both audio streams are actively capturing.
    @Published var isRecording = false

    /// Human-readable description of the current engine state.
    /// Suitable for display directly in the UI.
    @Published var statusMessage = "Idle"

    /// URL of the most recently completed mixed WAV file.
    /// `nil` until at least one successful recording has been stopped.
    @Published var lastRecordingURL: URL?

    // MARK: - System audio capture (ScreenCaptureKit)
    private var stream: SCStream?
    private let sampleHandlerQueue = DispatchQueue(label: "com.meetingrecorder.scstream.audio")

    // MARK: - Microphone capture (AVAudioEngine)
    private let micEngine = AVAudioEngine()

    // MARK: - File writing
    // All file/converter access after setup happens on writeQueue (serial),
    // so cross-thread access is safe even though the callbacks arrive on
    // the SCStream queue and the AVAudioEngine tap thread.
    private let writeQueue = DispatchQueue(label: "com.meetingrecorder.filewrite")
    nonisolated(unsafe) private var micFile: AVAudioFile?
    nonisolated(unsafe) private var systemFile: AVAudioFile?
    nonisolated(unsafe) private var micConverter: AVAudioConverter?
    nonisolated(unsafe) private var systemConverter: AVAudioConverter?

    private var micURL: URL?
    private var systemURL: URL?
    private var mixedURL: URL?

    // Common format both sources get converted to before writing.
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48000,
                                             channels: 1,
                                             interleaved: false)!

    // MARK: - Start

    /// Begin a new recording session.
    ///
    /// Creates fresh temp files, starts the ScreenCaptureKit stream for system
    /// audio, and installs an AVAudioEngine tap for the microphone.
    /// Calling this while already recording is a no-op.
    ///
    /// - Note: Any error during setup calls `stopRecording(discard: true)`
    ///   internally to guarantee no partial state is left behind.
    func startRecording() async {
        guard !isRecording else { return }

        do {
            // 1. Prepare output files in ~/Documents/MeetingRecordings/
            let (mixed, mic, system) = try makeOutputURLs()
            mixedURL = mixed
            micURL = mic
            systemURL = system

            micFile = try AVAudioFile(forWriting: mic,
                                      settings: outputFormat.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
            systemFile = try AVAudioFile(forWriting: system,
                                         settings: outputFormat.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)

            // 2. Start system-audio capture (the call / everyone else)
            try await startSystemAudioCapture()

            // 3. Start microphone capture (your voice)
            try startMicCapture()

            isRecording = true
            statusMessage = "Recording… (system audio + mic)"
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
            await stopRecording(discard: true)
        }
    }

    // MARK: - System audio via ScreenCaptureKit

    private func startSystemAudioCapture() async throws {
        // Get shareable content (required to build a filter).
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display found for capture."])
        }

        // We only care about AUDIO, but SCStream requires a display filter.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true                 // <-- the key line: grab system audio
        config.excludesCurrentProcessAudio = true   // don't record our own app's sound
        config.sampleRate = 48000
        config.channelCount = 1
        // Keep video minimal (we must request something, but we ignore it).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio,
                                   sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - Microphone via AVAudioEngine

    private func startMicCapture() throws {
        let input = micEngine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        micConverter = AVAudioConverter(from: inputFormat, to: outputFormat)

        // Tap the mic. Runs continuously and independently of system capture.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.writeQueue.async {
                guard let converter = self.micConverter,
                      let converted = Self.convert(buffer, with: converter),
                      let file = self.micFile else { return }
                try? file.write(from: converted)
            }
        }

        micEngine.prepare()
        try micEngine.start()
    }

    // MARK: - Conversion helper

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let outFormat = converter.outputFormat
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: capacity) else { return nil }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return nil }
        return out
    }

    // MARK: - Stop (records → mix → final file)

    /// Stop capturing, mix the two temp tracks into a single WAV, and clean up.
    ///
    /// - Parameter discard: When `true` (used internally on startup failure),
    ///   skips mixing and deletes all temp files without updating
    ///   `lastRecordingURL`.  Defaults to `false`.
    ///
    /// The sequence is:
    /// 1. Stop SCStream and remove the AVAudioEngine tap.
    /// 2. Drain `writeQueue` so every in-flight buffer is flushed to disk.
    /// 3. Mix mic + system temp files into the final output WAV.
    /// 4. Delete the hidden temp files.
    func stopRecording(discard: Bool = false) async {
        // Stop system audio
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Stop mic
        micEngine.inputNode.removeTap(onBus: 0)
        if micEngine.isRunning { micEngine.stop() }

        // Close files — do it ON the write queue so any in-flight
        // buffer writes finish first.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                self.micFile = nil
                self.systemFile = nil
                self.micConverter = nil
                self.systemConverter = nil
                cont.resume()
            }
        }

        defer {
            isRecording = false
        }

        guard !discard, let mic = micURL, let system = systemURL, let mixed = mixedURL else {
            cleanupTempFiles()
            return
        }

        // Mix the two recordings into the final file.
        statusMessage = "Mixing…"
        do {
            try Self.mix(micURL: mic, systemURL: system, into: mixed, format: outputFormat)
            lastRecordingURL = mixed
            statusMessage = "Saved: \(mixed.lastPathComponent)"
            cleanupTempFiles()
        } catch {
            // Mixing failed — keep the raw tracks so nothing is lost.
            statusMessage = "Mix failed (\(error.localizedDescription)). Raw tracks kept."
            lastRecordingURL = system   // call audio is usually the more important track
        }
    }

    /// Sum two mono 48 kHz float32 WAV files sample-by-sample into `output`.
    ///
    /// Both files must be the format produced by `outputFormat` (Float32, 48 kHz, mono).
    /// The shorter track is zero-padded so the output length equals the longer track.
    /// The sum is hard-clipped to ±1.0 to prevent digital overs.
    ///
    /// - Parameters:
    ///   - micURL: Temporary WAV containing the microphone track.
    ///   - systemURL: Temporary WAV containing the system-audio track.
    ///   - output: Destination URL for the final mixed file.
    ///   - format: The shared `AVAudioFormat` all three files use.
    /// - Throws: Any `AVAudioFile` read/write error.
    private nonisolated static func mix(micURL: URL, systemURL: URL,
                                        into output: URL,
                                        format: AVAudioFormat) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: systemURL)
        let outFile = try AVAudioFile(forWriting: output,
                                      settings: format.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)

        let chunk: AVAudioFrameCount = 4096
        guard let micBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let sysBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw NSError(domain: "MeetingRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate mix buffers."])
        }

        while true {
            micBuf.frameLength = 0
            sysBuf.frameLength = 0
            if micFile.framePosition < micFile.length {
                try micFile.read(into: micBuf, frameCount: chunk)
            }
            if sysFile.framePosition < sysFile.length {
                try sysFile.read(into: sysBuf, frameCount: chunk)
            }

            let frames = max(micBuf.frameLength, sysBuf.frameLength)
            if frames == 0 { break }

            outBuf.frameLength = frames
            let m = micBuf.floatChannelData![0]
            let s = sysBuf.floatChannelData![0]
            let o = outBuf.floatChannelData![0]
            let micN = Int(micBuf.frameLength)
            let sysN = Int(sysBuf.frameLength)

            for i in 0..<Int(frames) {
                let mv = i < micN ? m[i] : 0
                let sv = i < sysN ? s[i] : 0
                o[i] = max(-1.0, min(1.0, mv + sv))   // sum + hard clip
            }
            try outFile.write(from: outBuf)
        }
    }

    private func cleanupTempFiles() {
        if let micURL { try? FileManager.default.removeItem(at: micURL) }
        if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
    }

    // MARK: - Helpers

    private func makeOutputURLs() throws -> (mixed: URL, mic: URL, system: URL) {
        let docs = try FileManager.default.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = docs.appendingPathComponent("MeetingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let mixed = folder.appendingPathComponent("meeting-\(stamp).wav")
        let mic = folder.appendingPathComponent(".meeting-\(stamp).mic.wav")
        let system = folder.appendingPathComponent(".meeting-\(stamp).system.wav")
        return (mixed, mic, system)
    }
}

// MARK: - SCStreamOutput (system audio callback)

extension AudioCaptureEngine: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer -> AVAudioPCMBuffer
        guard let pcm = sampleBuffer.toPCMBuffer() else { return }

        // Convert + write on the serial write queue, preserving buffer order
        writeQueue.async { [weak self] in
            guard let self else { return }
            if self.systemConverter == nil {
                self.systemConverter = AVAudioConverter(from: pcm.format, to: self.outputFormatNonisolated)
            }
            guard let converter = self.systemConverter,
                  let converted = Self.convert(pcm, with: converter),
                  let file = self.systemFile else { return }
            try? file.write(from: converted)
        }
    }

    // outputFormat is MainActor-isolated; expose a nonisolated copy for the callback.
    private nonisolated var outputFormatNonisolated: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: 48000,
                      channels: 1,
                      interleaved: false)!
    }
}

// MARK: - CMSampleBuffer -> AVAudioPCMBuffer helper

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbdVar = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &asbdVar) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcm.frameLength = frameCount

        let bufferList = pcm.mutableAudioBufferList
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0,
            frameCount: Int32(frameCount),
            into: bufferList
        )
        return pcm
    }
}
