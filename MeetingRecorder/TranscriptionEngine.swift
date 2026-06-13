//
//  TranscriptionEngine.swift
//  MeetingRecorder
//
//  Transcribes a recorded WAV file to text using Apple's SFSpeechRecognizer.
//
//  Design notes:
//  ─────────────────────────────────────────────────────────────────────────
//  • Uses SFSpeechURLRecognitionRequest (file-based, not live microphone).
//  • Server-side recognition (requiresOnDeviceRecognition = false) is used
//    for best accuracy and to support recordings longer than ~1 minute.
//    Requires an active internet connection.
//  • Punctuation is added automatically via request.addsPunctuation = true.
//  • On success the transcript is written as a UTF-8 .txt file alongside
//    the source WAV so both files stay together in MeetingRecordings/.
//  • Cancellation via cancel() stops the in-flight SFSpeechRecognitionTask.
//
//  Requires:
//    NSSpeechRecognitionUsageDescription in Info.plist
//    macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//
//  Author: Ibrahim Sultan
//

import Foundation
import Speech

// MARK: - Error type

/// Errors that can be thrown during the transcription pipeline.
enum TranscriptionError: LocalizedError {

    /// The user denied speech recognition access in System Settings.
    case notAuthorized

    /// SFSpeechRecognizer is unavailable (no internet, locale not supported, etc.).
    case recognizerUnavailable

    /// Recognition completed but returned an empty string.
    case noResult

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access was denied. Go to System Settings → Privacy & Security → Speech Recognition and allow MeetingRecorder."
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable right now. Check your internet connection and try again."
        case .noResult:
            return "No speech was detected in the recording. The file may be silent or contain only background noise."
        }
    }
}

// MARK: - Engine

/// Observable engine that wraps `SFSpeechRecognizer` with an async interface
/// and SwiftUI-friendly published state.
///
/// Typical usage from a SwiftUI `Task {}`:
/// ```swift
/// await transcription.transcribe(audioURL: recordingURL)
/// ```
@MainActor
final class TranscriptionEngine: ObservableObject {

    // MARK: Published state

    /// `true` while an `SFSpeechRecognitionTask` is running.
    @Published var isTranscribing = false

    /// The recognised text from the most recent successful transcription.
    /// Empty string until `transcribe()` completes.
    @Published var transcript = ""

    /// URL of the saved `.txt` file. Set after a successful transcription;
    /// `nil` until then.
    @Published var transcriptURL: URL?

    /// Human-readable status for the UI (progress messages, errors).
    @Published var status = ""

    // MARK: Private

    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Public API

    /// Transcribe the WAV at `audioURL` and publish the results.
    ///
    /// Steps:
    /// 1. Request (or verify) speech recognition authorisation.
    /// 2. Create an `SFSpeechURLRecognitionRequest` for the file.
    /// 3. Run the recognition task; wait for `isFinal == true`.
    /// 4. Write the transcript to a `.txt` file beside the WAV.
    ///
    /// If any step fails, `status` is updated with a user-readable message
    /// and `isTranscribing` is set back to `false` — no crash, no partial state.
    ///
    /// - Parameter audioURL: The mixed WAV produced by `AudioCaptureEngine`.
    func transcribe(audioURL: URL) async {
        transcript = ""
        transcriptURL = nil
        isTranscribing = true
        status = "Requesting speech recognition access…"

        do {
            // ── 1. Authorization ─────────────────────────────────────────
            try await requestAuthorization()

            // ── 2. Build recognizer ──────────────────────────────────────
            // en-US locale; swap to a different identifier for other languages.
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  recognizer.isAvailable else {
                throw TranscriptionError.recognizerUnavailable
            }

            status = "Transcribing… (server-side, may take a moment)"

            // ── 3. Run recognition ───────────────────────────────────────
            let text = try await recognize(url: audioURL, with: recognizer)
            transcript = text

            // ── 4. Save .txt alongside the WAV ───────────────────────────
            let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            transcriptURL = txtURL
            status = "Saved: \(txtURL.lastPathComponent)"

        } catch {
            status = "Transcription failed — \(error.localizedDescription)"
        }

        isTranscribing = false
    }

    /// Cancel an in-progress transcription immediately.
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isTranscribing = false
        status = "Cancelled."
    }

    // MARK: - Private helpers

    /// Wraps the callback-based `SFSpeechRecognizer.requestAuthorization` as async/throws.
    private func requestAuthorization() async throws {
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
    ///
    /// `requiresOnDeviceRecognition` is `false` so Apple's servers handle the request,
    /// which supports recordings well beyond the ~1-minute on-device limit.
    ///
    /// - Parameters:
    ///   - url: Audio file URL (WAV, M4A, etc.).
    ///   - recognizer: An available `SFSpeechRecognizer`.
    /// - Returns: The best-transcription formatted string.
    /// - Throws: `TranscriptionError.noResult` if recognition completes empty,
    ///   or any `Error` surfaced by the recognition task.
    private func recognize(url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false   // wait for the full result
            request.requiresOnDeviceRecognition  = false // server-side for accuracy + long files
            request.addsPunctuation              = true  // natural-reading output

            var resumed = false   // guard against the callback firing more than once

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
