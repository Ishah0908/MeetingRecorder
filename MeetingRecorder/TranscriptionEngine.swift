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

/// Languages the user can transcribe in. The raw value is the SFSpeechRecognizer
/// locale identifier. Add more cases here to offer more languages — any locale
/// listed by `SFSpeechRecognizer.supportedLocales()` will work.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case english        = "en-US"
    case spanishSpain   = "es-ES"
    case spanishMexico  = "es-MX"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english:       return "English"
        case .spanishSpain:  return "Spanish (Spain)"
        case .spanishMexico: return "Spanish (Mexico)"
        }
    }
}

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

    private var consecutiveFailures = 0

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
        let req = request
        let t = task
        request = nil
        task = nil
        lock.unlock()
        req?.endAudio()
        t?.finish()
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

        // Track the most recent text so we can still commit something if the
        // task ends with an error rather than a clean isFinal.
        var lastText = ""

        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                lastText = text
                // Any real output means the recognizer is healthy — clear the
                // failure counter so an earlier hiccup doesn't trip the cap.
                if !text.isEmpty { self.lock.lock(); self.consecutiveFailures = 0; self.lock.unlock() }
                self.onPartial?(text)

                if result.isFinal {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.onSegment?(text, Date())
                    }
                    self.restart(afterError: false)
                }
            }

            if error != nil {
                if !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onSegment?(lastText, Date())
                }
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

        if failures >= 8 {
            lock.lock(); running = false; lock.unlock()
            onError?("Live transcription stopped after repeated recognition errors.")
            return
        }

        if afterError {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.beginRequest()
            }
        } else {
            beginRequest()
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

    /// Language used for transcription (live and file). Changeable while idle.
    @Published var language: TranscriptionLanguage = .english

    // MARK: Private

    // Two independent live recognizers, one per audio source. nonisolated(unsafe)
    // so the nonisolated append methods can reach them from the audio thread.
    // Recreated for the chosen language at the start of each live session.
    nonisolated(unsafe) private var you: SourceRecognizer
    nonisolated(unsafe) private var others: SourceRecognizer

    // File-mode task.
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        let locale = Locale(identifier: TranscriptionLanguage.english.rawValue)
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

        // Build fresh recognizers for the selected language.
        let locale = Locale(identifier: language.rawValue)
        you = SourceRecognizer(label: "You", locale: locale)
        others = SourceRecognizer(label: "Others", locale: locale)

        guard you.isUsable, others.isUsable else {
            status = "Live transcription off — \(language.displayName) isn't available for recognition on this Mac."
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
        status = "Live transcription running (\(language.displayName))…"
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

        // Interleave the two streams by finalize time into one conversation.
        let ordered = segments.sorted { $0.time < $1.time }
        let text = ordered.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        transcript = text

        if let audioURL {
            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            do {
                try text.write(to: txtURL, atomically: true, encoding: .utf8)
                transcriptURL = txtURL
                status = "Saved: \(txtURL.lastPathComponent)"
            } catch {
                status = "Transcript captured but couldn't be saved — \(error.localizedDescription)"
            }
        } else {
            status = "Transcript captured."
        }
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

            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
                  recognizer.isAvailable else {
                throw TranscriptionError.recognizerUnavailable
            }

            status = "Transcribing file (\(language.displayName))…"
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
