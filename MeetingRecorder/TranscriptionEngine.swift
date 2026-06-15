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

/// Several consecutive same-speaker segments merged into one flowing block, so
/// the transcript reads as continuous prose instead of many short lines.
struct TranscriptGroup: Identifiable {
    let id: UUID
    let speaker: String
    let text: String
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

    /// Text recognized in the CURRENT request so far. Partials are cumulative,
    /// so this grows as the speaker talks. Guarded by `lock` (instance state, not
    /// a closure local) so the stall watchdog can flush it before recycling a
    /// frozen request. Committed — never just the `isFinal` text — whenever a
    /// request ends, so nothing is lost even on an empty final.
    private var accumulated = ""

    /// When the current request last produced a result, and whether any audio
    /// has been appended since. The watchdog uses these to spot a silent stall:
    /// audio flowing in but no recognition coming out, the failure mode that
    /// freezes a stream partway through a long meeting.
    private var lastResultAt = Date()
    private var audioSinceResult = false
    private var watchdog: DispatchSourceTimer?

    /// How long a request may take in audio with no result before the watchdog
    /// force-recycles it. Long enough to ride out normal pauses, short enough to
    /// recover quickly.
    private let stallTimeout: TimeInterval = 12

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
        lock.lock(); running = true; stopping = false; lock.unlock()
        beginRequest()
        startWatchdog()
    }

    /// Append a captured audio buffer. Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let req = request; audioSinceResult = true; lock.unlock()
        req?.append(buffer)
    }

    /// Stop recognition and release the current task/request.
    func stop() {
        stopWatchdog()
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

    /// Commit the accumulated text as a finished segment and clear it.
    /// Idempotent: a call with nothing accumulated does nothing.
    private func commitAccumulated() {
        lock.lock()
        let text = accumulated
        accumulated = ""
        lock.unlock()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSegment?(text, Date())
    }

    private func beginRequest() {
        lock.lock(); let go = running; lock.unlock()
        guard go else { return }

        guard let recognizer, recognizer.isAvailable else {
            // The on-device recognizer can flip to "unavailable" transiently
            // during a long session (system throttling, resource pressure). The
            // old code returned here and the stream died silently for the rest
            // of the meeting. Instead, keep retrying so it resumes the moment
            // the recognizer is back — that's what makes long meetings reliable.
            scheduleRetry(afterError: true)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = preferOnDevice
        req.addsPunctuation = true

        lock.lock()
        self.request = req
        self.lastResultAt = Date()
        self.audioSinceResult = false
        lock.unlock()

        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString

                self.lock.lock()
                self.lastResultAt = Date()
                self.audioSinceResult = false
                let prev = self.accumulated
                // Detect an internal reset: the recognizer dropped its earlier
                // text and started a fresh utterance within the same request
                // (happens after a pause). Only a dramatic shrink triggers it,
                // so normal word-by-word refinement (which grows) never misfires.
                let isReset = !prev.isEmpty && !text.isEmpty
                    && text.count + 12 < prev.count
                    && !prev.hasPrefix(String(text.prefix(8)))
                if isReset { self.accumulated = "" }
                if !text.isEmpty {
                    self.accumulated = text
                    self.consecutiveFailures = 0   // healthy output
                }
                self.lock.unlock()

                // Commit the pre-reset text (outside the lock — onSegment hops
                // to the main actor).
                if isReset, !prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onSegment?(prev, Date())
                }

                self.onPartial?(text)

                if result.isFinal {
                    if !self.isStopping { self.commitAccumulated() }
                    self.restart(afterError: false)
                }
            }

            if let error {
                #if DEBUG
                print("MeetingRecorder speech error [\(self.label)]: \(error.localizedDescription)")
                #endif
                if !self.isStopping { self.commitAccumulated() }
                self.restart(afterError: true)
            }
        }

        lock.lock(); self.task = t; lock.unlock()
    }

    /// Tear down the finished request and, if still running, schedule a fresh
    /// one so recognition continues for the whole meeting.
    private func restart(afterError: Bool) {
        lock.lock()
        let stillRunning = running
        request = nil
        task = nil
        if afterError { consecutiveFailures += 1 } else { consecutiveFailures = 0 }
        lock.unlock()
        guard stillRunning else { return }
        scheduleRetry(afterError: afterError)
    }

    /// Schedule the next `beginRequest`. Clean rollovers restart almost
    /// immediately; errors and transient unavailability back off (capped) so we
    /// never hammer a failing recognizer, but we ALWAYS keep retrying so the
    /// stream is self-healing for the entire meeting. The failure counter is
    /// reset whenever real text comes back, so the cadence snaps back to fast as
    /// soon as recognition is working again.
    private func scheduleRetry(afterError: Bool) {
        lock.lock(); let failures = consecutiveFailures; lock.unlock()
        let delay = afterError
            ? min(0.2 * pow(2.0, Double(min(max(failures - 1, 0), 4))), 1.5)   // 0.2s → 1.5s
            : 0.05
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.beginRequest()
        }
    }

    // MARK: Stall watchdog

    /// Periodically checks for a silently stalled request — audio is still being
    /// appended but the recognizer hasn't produced a result for `stallTimeout` —
    /// and force-recycles it. Without this, a single stalled request freezes its
    /// stream for the rest of the call while recording (and the WAV) carry on,
    /// which is exactly the "transcript cut off partway" symptom.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in self?.checkStall() }
        lock.lock(); watchdog?.cancel(); watchdog = timer; lock.unlock()
        timer.resume()
    }

    private func stopWatchdog() {
        lock.lock(); let w = watchdog; watchdog = nil; lock.unlock()
        w?.cancel()
    }

    private func checkStall() {
        lock.lock()
        let go = running
        let stalled = audioSinceResult && Date().timeIntervalSince(lastResultAt) > stallTimeout
        let req = request
        let t = task
        if go && stalled {
            // Claim the recycle: drop the frozen request/task so the finalize
            // callback (if it ever fires) can't also trigger a second restart.
            request = nil
            task = nil
        }
        lock.unlock()
        guard go, stalled else { return }

        // Flush whatever we managed to recognize so it isn't lost, then tear the
        // frozen request down and spin up a fresh one.
        if !isStopping { commitAccumulated() }
        req?.endAudio()
        t?.cancel()
        scheduleRetry(afterError: false)
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

    /// Live segments merged into flowing per-speaker blocks (commit order),
    /// for continuous on-screen display.
    var groupedSegments: [TranscriptGroup] {
        Self.mergeRuns(segments)
    }

    /// Build the full transcript text: the two streams interleaved by time and
    /// merged into flowing per-speaker blocks, each tagged with its speaker.
    func assembledTranscript() -> String {
        Self.mergeRuns(segments.sorted { $0.time < $1.time })
            .map { "[\($0.speaker)] \($0.text)" }
            .joined(separator: "\n")
    }

    /// Merge runs of consecutive same-speaker segments into single blocks.
    private static func mergeRuns(_ segs: [TranscriptSegment]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        for seg in segs {
            if let last = groups.last, last.speaker == seg.speaker {
                groups[groups.count - 1] = TranscriptGroup(
                    id: last.id, speaker: last.speaker, text: last.text + " " + seg.text)
            } else {
                groups.append(TranscriptGroup(id: seg.id, speaker: seg.speaker, text: seg.text))
            }
        }
        return groups
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
