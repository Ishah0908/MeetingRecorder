//
//  TranscriptionEngine.swift
//  MeetingRecorder
//
//  Transcribes meetings to text using Apple's SFSpeechRecognizer. Two modes:
//
//  1. LIVE (primary) — text appears as people talk.
//     Because the app captures two separate audio sources (your microphone and
//     the system audio = everyone else on the call), we run TWO live recognizers
//     in parallel and label their output "You" and "Others". This gives reliable
//     two-way speaker separation, which is the most Apple's framework can do
//     natively — SFSpeechRecognizer has NO built-in multi-speaker diarization.
//     Telling apart individual remote participants would require an external
//     model (e.g. pyannote / WhisperX) or a cloud API.
//
//  2. FILE (fallback) — transcribe a finished WAV after the fact via
//     SFSpeechURLRecognitionRequest. Single stream, no speaker labels.
//
//  Live design notes:
//  ─────────────────────────────────────────────────────────────────────────
//  • Each source is driven by a `SourceRecognizer` that owns one
//    SFSpeechAudioBufferRecognitionRequest + task and exposes a thread-safe,
//    nonisolated `append(_:)` so the audio callbacks can feed it directly.
//  • On-device recognition is preferred (requiresOnDeviceRecognition) so the
//    session can run continuously for a long meeting and works offline.
//  • When a task finalizes a segment (e.g. after a pause), the text is committed
//    and a fresh request is started automatically — the standard continuous
//    dictation pattern.
//  • Finalized segments are timestamped at the moment they commit, then sorted
//    by time when saved, so the two streams interleave into one conversation.
//
//  Requires:
//    NSSpeechRecognitionUsageDescription in Info.plist
//    macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//
//  Author: Ibrahim Sultan
//

import Foundation
import Speech
import AVFoundation

// MARK: - Error type

/// Errors that can be thrown during the transcription pipeline.
enum TranscriptionError: LocalizedError {

    /// The user denied speech recognition access in System Settings.
    case notAuthorized

    /// SFSpeechRecognizer is unavailable (no internet for server mode, locale
    /// not supported, etc.).
    case recognizerUnavailable

    /// Recognition completed but returned an empty string.
    case noResult

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access was denied. Go to System Settings → Privacy & Security → Speech Recognition and allow MeetingRecorder."
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable right now. For a supported language and (if not on-device) an internet connection are required."
        case .noResult:
            return "No speech was detected in the recording. The file may be silent or contain only background noise."
        }
    }
}

// MARK: - Language

// MARK: - Transcript segment

/// One finalized chunk of speech attributed to a source.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    /// "You" (microphone) or "Others" (system audio).
    let speaker: String
    let text: String
    /// When this segment was finalized — used to interleave the two streams.
    let time: Date
}

// MARK: - Per-source live recognizer

/// Drives one continuous live recognition stream for a single audio source.
///
/// Lives outside the `@MainActor` so its `append(_:)` can be called directly
/// from the real-time audio callbacks. All shared state is guarded by a lock,
/// and result callbacks are delivered on whatever queue the Speech framework
/// uses — the owner is responsible for hopping to the main actor.
final class SourceRecognizer {

    /// Label used for this source in the transcript ("You" / "Others").
    let label: String

    private let recognizer: SFSpeechRecognizer?
    private let preferOnDevice: Bool

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var stopping = false

    private var consecutiveFailures = 0

    /// `true` once `stop()` has been called — the engine flushes the final
    /// partial itself, so the recognizer must not also commit on teardown
    /// (that would duplicate the last sentence).
    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }; return stopping
    }

    /// Latest partial (in-progress) text for this source.
    var onPartial: ((String) -> Void)?
    /// A finalized chunk of text plus the time it finalized.
    var onSegment: ((String, Date) -> Void)?
    /// Called if recognition gives up after repeated immediate failures.
    var onError: ((String) -> Void)?

    init(label: String, locale: Locale) {
        self.label = label
        let r = SFSpeechRecognizer(locale: locale)
        self.recognizer = r
        self.preferOnDevice = r?.supportsOnDeviceRecognition ?? false
    }

    /// `true` if a recognizer for the locale exists and is available.
    var isUsable: Bool { recognizer?.isAvailable ?? false }

    /// Begin continuous recognition.
    func start() {
        lock.lock(); running = true; lock.unlock()
        beginRequest()
    }

    /// Append a captured audio buffer. Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let req = request; lock.unlock()
        req?.append(buffer)
    }

    /// Stop recognition and release the current task/request.
    func stop() {
        lock.lock()
        running = false
        stopping = true
        let req = request
        let t = task
        request = nil
        task = nil
        lock.unlock()
        req?.endAudio()
        t?.cancel()
    }

    // MARK: Private

    private func beginRequest() {
        guard let recognizer, recognizer.isAvailable else { return }
        lock.lock()
        guard running else { lock.unlock(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = preferOnDevice
        req.addsPunctuation = true
        self.request = req
        lock.unlock()

        // The full text recognized in THIS request so far. Partials are
        // cumulative, so this grows as the user speaks. We commit it (never just
        // the `isFinal` text) whenever the request ends, so nothing is lost even
        // if the final result comes back empty.
        var accumulated = ""

        // Commit the accumulated text as a finished segment and reset it.
        // Idempotent: a second call with nothing new does nothing.
        let commitAccumulated: () -> Void = { [weak self] in
            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.onSegment?(accumulated, Date())
            accumulated = ""
        }

        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString

                // Detect an internal reset: the recognizer dropped its earlier
                // text and started a fresh utterance within the same request
                // (happens after a pause). Commit what we had before it's
                // overwritten. Only triggers on a dramatic shrink so normal
                // word-by-word refinement (which grows) never misfires.
                if !accumulated.isEmpty, !text.isEmpty,
                   text.count + 12 < accumulated.count,
                   !accumulated.hasPrefix(String(text.prefix(8))) {
                    commitAccumulated()
                }

                if !text.isEmpty {
                    accumulated = text
                    // Healthy output — clear the failure counter.
                    self.lock.lock(); self.consecutiveFailures = 0; self.lock.unlock()
                }
                self.onPartial?(text)

                if result.isFinal {
                    if !self.isStopping { commitAccumulated() }
                    self.restart(afterError: false)
                }
            }

            if let error {
                #if DEBUG
                print("MeetingRecorder speech error [\(self.label)]: \(error.localizedDescription)")
                #endif
                if !self.isStopping { commitAccumulated() }
                self.restart(afterError: true)
            }
        }

        lock.lock(); self.task = t; lock.unlock()
    }

    /// Tear down the finished request and, if still running, start a fresh one
    /// so recognition continues for the whole meeting.
    ///
    /// A clean finalization restarts immediately. An error restarts after a
    /// short delay, and after several back-to-back errors we stop entirely so a
    /// permanently-failing recognizer can't spin in a tight loop.
    private func restart(afterError: Bool) {
        lock.lock()
        let stillRunning = running
        request = nil
        task = nil
        if afterError { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
        let failures = consecutiveFailures
        lock.unlock()

        guard stillRunning else { return }

        // Self-healing: never permanently stop. On repeated errors we back off
        // (capped) so we don't hammer a failing recognizer — e.g. the "Others"
        // stream getting silence when nothing is playing — but we keep retrying
        // so transcription resumes the instant there's speech again. A clean
        // isFinal rollover restarts almost immediately. The failure counter is
        // reset whenever any real text comes back, so the cadence snaps back to
        // fast as soon as recognition is working.
        let delay = afterError
            ? min(0.2 * pow(2.0, Double(min(failures - 1, 4))), 1.5)   // 0.2s → 1.5s
            : 0.05

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginRequest()
        }
    }
}

// MARK: - Engine

/// Observable engine exposing both live and file-based transcription with
/// SwiftUI-friendly published state.
@MainActor
final class TranscriptionEngine: ObservableObject {

    // MARK: Published — live

    /// `true` while live recognition is running.
    @Published var isLive = false

    /// In-progress (not yet finalized) text from the microphone stream.
    @Published var livePartialYou = ""

    /// In-progress (not yet finalized) text from the system-audio stream.
    @Published var livePartialOthers = ""

    /// Finalized, speaker-labeled chunks in commit order.
    @Published var segments: [TranscriptSegment] = []

    // MARK: Published — file mode / shared

    /// `true` while a file-based `transcribe(audioURL:)` is running.
    @Published var isTranscribing = false

    /// The full assembled transcript text (set on stop, or by file mode).
    @Published var transcript = ""

    /// URL of the saved `.txt` file once written; `nil` until then.
    @Published var transcriptURL: URL?

    /// Human-readable status for the UI.
    @Published var status = ""

    // MARK: Private

    // One recognizer per audio source. nonisolated(unsafe) so the nonisolated
    // append methods can reach them from the audio thread.
    nonisolated(unsafe) private var you: SourceRecognizer
    nonisolated(unsafe) private var others: SourceRecognizer

    // File-mode task.
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        let locale = Locale(identifier: "en-US")
        you = SourceRecognizer(label: "You", locale: locale)
        others = SourceRecognizer(label: "Others", locale: locale)
    }

    // MARK: - Live API

    /// Forward a microphone buffer into the "You" recognizer.
    /// Nonisolated so it can be called straight from the audio callback.
    nonisolated func appendYou(_ buffer: AVAudioPCMBuffer) { you.append(buffer) }

    /// Forward a system-audio buffer into the "Others" recognizer.
    nonisolated func appendOthers(_ buffer: AVAudioPCMBuffer) { others.append(buffer) }

    /// Begin live transcription. Requests speech authorization first; if it is
    /// denied or recognizers are unavailable, this returns without throwing —
    /// recording can still proceed, just without live text.
    func startLive() async {
        // Reset live state for a fresh session.
        segments = []
        livePartialYou = ""
        livePartialOthers = ""
        transcript = ""
        transcriptURL = nil

        do {
            try await requestAuthorization()
        } catch {
            status = "Live transcription off — \(error.localizedDescription)"
            isLive = false
            return
        }

        // Fresh recognizers per source.
        let locale = Locale(identifier: "en-US")
        you = SourceRecognizer(label: "You", locale: locale)
        others = SourceRecognizer(label: "Others", locale: locale)

        guard you.isUsable, others.isUsable else {
            status = "Live transcription off — speech recognition isn't available on this Mac."
            isLive = false
            return
        }

        // Wire callbacks. They fire on a background queue, so hop to the main
        // actor before touching @Published state.
        you.onPartial = { [weak self] text in
            Task { @MainActor in self?.livePartialYou = text }
        }
        you.onSegment = { [weak self] text, time in
            Task { @MainActor in self?.commit(speaker: "You", text: text, time: time) }
        }
        others.onPartial = { [weak self] text in
            Task { @MainActor in self?.livePartialOthers = text }
        }
        others.onSegment = { [weak self] text, time in
            Task { @MainActor in self?.commit(speaker: "Others", text: text, time: time) }
        }
        let onErr: (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }
        you.onError = onErr
        others.onError = onErr

        you.start()
        others.start()
        isLive = true
        status = "Live transcription running…"
    }

    /// Stop live transcription, flush any trailing partials, assemble the
    /// interleaved transcript and (if a recording URL is given) save it as a
    /// `.txt` beside the WAV.
    ///
    /// - Parameter audioURL: The mixed WAV from `AudioCaptureEngine`, used to
    ///   derive the `.txt` path. Pass `nil` to skip saving.
    func stopLive(besideAudio audioURL: URL?) async {
        guard isLive else { return }

        you.stop()
        others.stop()
        isLive = false

        // Flush any leftover in-progress text as final segments.
        if !livePartialYou.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit(speaker: "You", text: livePartialYou, time: Date())
        }
        if !livePartialOthers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit(speaker: "Others", text: livePartialOthers, time: Date())
        }

        guard !segments.isEmpty else {
            status = "No speech was transcribed."
            return
        }

        transcript = assembledTranscript()

        if let audioURL {
            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            do {
                try transcript.write(to: txtURL, atomically: true, encoding: .utf8)
                transcriptURL = txtURL
                status = "Saved: \(txtURL.lastPathComponent)"
            } catch {
                status = "Transcript captured but couldn't be saved — \(error.localizedDescription)"
            }
        } else {
            status = "Transcript captured."
        }
    }

    /// Build the full transcript text: the two streams interleaved by time,
    /// each line tagged with its speaker.
    func assembledTranscript() -> String {
        segments.sorted { $0.time < $1.time }
            .map { "[\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Append a finalized segment and clear that source's live partial.
    private func commit(speaker: String, text: String, time: Date) {
        segments.append(TranscriptSegment(speaker: speaker, text: text, time: time))
        if speaker == "You" { livePartialYou = "" } else { livePartialOthers = "" }
    }

    // MARK: - File-based API (fallback / re-transcribe)

    /// Transcribe a finished WAV file after the fact (single stream, no speaker
    /// labels). Useful when live transcription wasn't available, or to redo a
    /// recording with server-side accuracy.
    ///
    /// - Parameter audioURL: The mixed WAV produced by `AudioCaptureEngine`.
    func transcribe(audioURL: URL) async {
        transcript = ""
        transcriptURL = nil
        isTranscribing = true
        status = "Requesting speech recognition access…"

        do {
            try await requestAuthorization()

            // File fallback uses English; the live path is the bilingual one,
            // and the offline diarize tool auto-detects + can translate.
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  recognizer.isAvailable else {
                throw TranscriptionError.recognizerUnavailable
            }

            status = "Transcribing file (English)…"
            let text = try await recognize(url: audioURL, with: recognizer)
            transcript = text

            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            transcriptURL = txtURL
            status = "Saved: \(txtURL.lastPathComponent)"

        } catch {
            status = "Transcription failed — \(error.localizedDescription)"
        }

        isTranscribing = false
    }

    /// Cancel an in-progress file-based transcription.
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isTranscribing = false
        status = "Cancelled."
    }

    // MARK: - Private helpers

    /// Wraps the callback-based `SFSpeechRecognizer.requestAuthorization` as async/throws.
    private func requestAuthorization() async throws {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            SFSpeechRecognizer.requestAuthorization { status in
                if status == .authorized {
                    cont.resume()
                } else {
                    cont.resume(throwing: TranscriptionError.notAuthorized)
                }
            }
        }
    }

    /// Run an `SFSpeechURLRecognitionRequest` and return the final transcript string.
    private func recognize(url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = false   // server-side for accuracy + long files
            request.addsPunctuation = true

            var resumed = false

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }

                if let error {
                    resumed = true
                    cont.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    resumed = true
                    let text = result.bestTranscription.formattedString
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cont.resume(throwing: TranscriptionError.noResult)
                    } else {
                        cont.resume(returning: text)
                    }
                }
            }
        }
    }
}
