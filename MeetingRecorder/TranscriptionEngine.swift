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
    /// The recognized text, in whatever language was detected.
    let text: String
    /// Detected language code for this chunk ("en-US", "es-ES", …).
    let languageCode: String
    /// When this segment was finalized — used to interleave the two streams.
    let time: Date
    /// English translation, filled in asynchronously for non-English chunks.
    var translation: String?

    /// Short uppercase language badge for the UI ("EN", "ES").
    var languageBadge: String { String(languageCode.prefix(2)).uppercased() }

    /// `true` when this chunk needs translating to English.
    var needsTranslation: Bool { !languageCode.hasPrefix("en") }
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
    /// A finalized chunk: text, an average confidence (0–1), and the time it
    /// finalized. Confidence is used to decide which language understood best.
    var onSegment: ((_ text: String, _ confidence: Double, _ time: Date) -> Void)?
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
                let transcription = result.bestTranscription
                let text = transcription.formattedString
                lastText = text
                // Any real output means the recognizer is healthy — clear the
                // failure counter so an earlier hiccup doesn't trip the cap.
                if !text.isEmpty { self.lock.lock(); self.consecutiveFailures = 0; self.lock.unlock() }
                self.onPartial?(text)

                if result.isFinal {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Average per-word confidence: the wrong-language
                        // recognizer scores low here, which is how we pick.
                        let segs = transcription.segments
                        let confidence = segs.isEmpty ? 0
                            : Double(segs.map(\.confidence).reduce(0, +)) / Double(segs.count)
                        self.onSegment?(text, confidence, Date())
                    }
                    self.restart(afterError: false)
                }
            }

            if error != nil {
                if !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.onSegment?(lastText, 0, Date())
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

// MARK: - Per-source bilingual transcriber

/// Runs an English and a Spanish recognizer on the SAME audio source and
/// decides, per phrase, which language actually understood the speech — so the
/// user never has to pick a language.
///
/// How detection works: `SFSpeechRecognizer` is locale-locked and can't
/// auto-detect, so we transcribe with both and compare. The recognizer hearing
/// the "wrong" language produces fewer words at lower confidence; the right one
/// wins. Finals from both languages that land in the same brief window (between
/// natural pauses) are batched and scored together, then only the winner is
/// emitted — so there are no duplicates.
final class SourceTranscriber {

    let label: String
    private let englishCode: String
    private let spanishCode: String
    private let english: SourceRecognizer
    private let spanish: SourceRecognizer

    /// Best current partial (live preview), regardless of language.
    var onPartial: ((String) -> Void)?
    /// A finalized chunk: text, detected language code, finalize time.
    var onSegment: ((_ text: String, _ language: String, _ time: Date) -> Void)?
    var onError: ((String) -> Void)?

    private struct Final { let text: String; let confidence: Double; let time: Date }

    private let lock = NSLock()
    private var partialEnglish = ""
    private var partialSpanish = ""
    private var batchEnglish: [Final] = []
    private var batchSpanish: [Final] = []
    private var flushWork: DispatchWorkItem?

    /// `true` if at least one of the two language recognizers is available.
    var isUsable: Bool { english.isUsable || spanish.isUsable }

    init(label: String, englishCode: String = "en-US", spanishCode: String = "es-ES") {
        self.label = label
        self.englishCode = englishCode
        self.spanishCode = spanishCode
        english = SourceRecognizer(label: "\(label)·en", locale: Locale(identifier: englishCode))
        spanish = SourceRecognizer(label: "\(label)·es", locale: Locale(identifier: spanishCode))

        english.onPartial = { [weak self] t in self?.handlePartial(t, isEnglish: true) }
        spanish.onPartial = { [weak self] t in self?.handlePartial(t, isEnglish: false) }
        english.onSegment = { [weak self] t, c, time in self?.handleFinal(t, c, time, isEnglish: true) }
        spanish.onSegment = { [weak self] t, c, time in self?.handleFinal(t, c, time, isEnglish: false) }
        english.onError = { [weak self] m in self?.onError?(m) }
        spanish.onError = { [weak self] m in self?.onError?(m) }
    }

    func start() {
        if english.isUsable { english.start() }
        if spanish.isUsable { spanish.start() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        english.append(buffer)
        spanish.append(buffer)
    }

    func stop() {
        lock.lock(); flushWork?.cancel(); flushWork = nil; lock.unlock()
        english.stop()
        spanish.stop()
        flush()   // emit anything still batched
    }

    // MARK: Arbitration

    private func handlePartial(_ text: String, isEnglish: Bool) {
        lock.lock()
        if isEnglish { partialEnglish = text } else { partialSpanish = text }
        let en = partialEnglish, es = partialSpanish
        lock.unlock()
        // Show whichever language currently has more words as the live preview.
        onPartial?(Self.wordCount(en) >= Self.wordCount(es) ? en : es)
    }

    private func handleFinal(_ text: String, _ confidence: Double, _ time: Date, isEnglish: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if isEnglish {
            batchEnglish.append(Final(text: trimmed, confidence: confidence, time: time))
            partialEnglish = ""
        } else {
            batchSpanish.append(Final(text: trimmed, confidence: confidence, time: time))
            partialSpanish = ""
        }
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        lock.unlock()
        // Debounce: wait briefly so the other language's final for the same
        // phrase can arrive and be compared before we emit.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func flush() {
        lock.lock()
        let en = batchEnglish, es = batchSpanish
        batchEnglish = []; batchSpanish = []
        flushWork = nil
        lock.unlock()

        if en.isEmpty && es.isEmpty { return }
        if es.isEmpty { return emit(en, englishCode) }
        if en.isEmpty { return emit(es, spanishCode) }
        // Both languages produced something — higher score wins.
        if Self.score(en) >= Self.score(es) { emit(en, englishCode) }
        else { emit(es, spanishCode) }
    }

    private func emit(_ batch: [Final], _ language: String) {
        guard let last = batch.last else { return }
        let text = batch.map(\.text).joined(separator: " ")
        onSegment?(text, language, last.time)
    }

    // Score favours more words AND higher confidence — the correct-language
    // transcription almost always has both.
    private static func score(_ batch: [Final]) -> Double {
        batch.reduce(0) { $0 + max($1.confidence, 0.05) * Double(wordCount($1.text)) }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" }.count
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

    // One bilingual transcriber per audio source (each runs English + Spanish
    // recognizers and auto-detects). nonisolated(unsafe) so the nonisolated
    // append methods can reach them from the audio thread.
    nonisolated(unsafe) private var you: SourceTranscriber
    nonisolated(unsafe) private var others: SourceTranscriber

    // File-mode task.
    private var recognitionTask: SFSpeechRecognitionTask?

    init() {
        you = SourceTranscriber(label: "You")
        others = SourceTranscriber(label: "Others")
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

        // Fresh bilingual transcribers (English + Spanish) per source.
        you = SourceTranscriber(label: "You")
        others = SourceTranscriber(label: "Others")

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
        you.onSegment = { [weak self] text, language, time in
            Task { @MainActor in self?.commit(speaker: "You", text: text, language: language, time: time) }
        }
        others.onPartial = { [weak self] text in
            Task { @MainActor in self?.livePartialOthers = text }
        }
        others.onSegment = { [weak self] text, language, time in
            Task { @MainActor in self?.commit(speaker: "Others", text: text, language: language, time: time) }
        }
        let onErr: (String) -> Void = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }
        you.onError = onErr
        others.onError = onErr

        you.start()
        others.start()
        isLive = true
        status = "Live transcription running (auto English/Spanish)…"
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

        // Flush any leftover in-progress text as final segments (assume English,
        // the safe default, since these never went through arbitration).
        if !livePartialYou.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit(speaker: "You", text: livePartialYou, language: "en-US", time: Date())
        }
        if !livePartialOthers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit(speaker: "Others", text: livePartialOthers, language: "en-US", time: Date())
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

    /// Build the full transcript text: streams interleaved by time, each line
    /// tagged with speaker and language, with the English translation appended
    /// for non-English chunks when available.
    func assembledTranscript() -> String {
        segments.sorted { $0.time < $1.time }.map { seg in
            var line = "[\(seg.speaker) · \(seg.languageBadge)] \(seg.text)"
            if seg.needsTranslation, let en = seg.translation, !en.isEmpty {
                line += "\n    → (EN) \(en)"
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// Append a finalized segment and clear that source's live partial.
    private func commit(speaker: String, text: String, language: String, time: Date) {
        segments.append(TranscriptSegment(speaker: speaker, text: text,
                                          languageCode: language, time: time, translation: nil))
        if speaker == "You" { livePartialYou = "" } else { livePartialOthers = "" }
    }

    /// Store an English translation for a previously-committed segment.
    /// Called by the view's translation task as results come back.
    func applyTranslation(id: UUID, english: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[i].translation = english
        if !isLive { transcript = assembledTranscript() }
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
