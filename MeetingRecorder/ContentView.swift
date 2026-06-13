//
//  ContentView.swift
//  MeetingRecorder
//
//  Main screen of the app. Binds the UI to two observable engines:
//    • AudioCaptureEngine  — manages the recording lifecycle
//    • TranscriptionEngine — transcribes a saved WAV on demand
//
//  Layout (top → bottom):
//    1. Animated recording indicator  — pulsing red circle while active
//    2. Status label                  — reflects the engine's current phase
//    3. Start / Stop button           — toggles startRecording / stopRecording
//    4. Last Recording box            — filename, Show in Finder, Transcribe button
//    5. Transcript panel              — appears after a successful transcription
//    6. Permission reminder           — non-blocking hint
//
//  Author : Ibrahim Sultan
//  Requires: macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//

import SwiftUI

/// Primary view. All recording and transcription logic lives in their
/// respective engines; this view handles only presentation and user interaction.
struct ContentView: View {

    /// Manages the full recording lifecycle (capture → mix → save).
    @StateObject private var engine = AudioCaptureEngine()

    /// Manages on-demand transcription of a saved WAV file.
    @StateObject private var transcription = TranscriptionEngine()

    /// Drives the pulsing animation on the recording indicator.
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 24) {

            // ── Recording indicator ──────────────────────────────────────────
            // Outer ring pulses (1.0 → 1.4) while recording; inner dot is red
            // while recording and grey while idle.
            ZStack {
                Circle()
                    .fill(engine.isRecording ? Color.red.opacity(0.15) : Color.clear)
                    .frame(width: 64, height: 64)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .animation(
                        engine.isRecording
                            ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                Circle()
                    .fill(engine.isRecording ? Color.red : Color.gray.opacity(0.4))
                    .frame(width: 28, height: 28)
            }
            .onChange(of: engine.isRecording) { _, recording in
                pulse = recording
            }

            // ── Status label ─────────────────────────────────────────────────
            // Shows "Idle", "Recording…", "Mixing…", or "Saved: filename".
            Text(engine.statusMessage)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            // ── Start / Stop button ──────────────────────────────────────────
            // Wrapped in Task so the async engine methods don't block the main thread.
            Button {
                Task {
                    if engine.isRecording {
                        await engine.stopRecording()
                    } else {
                        await engine.startRecording()
                    }
                }
            } label: {
                Label(
                    engine.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: engine.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                )
                .font(.title3.weight(.semibold))
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRecording ? .red : .accentColor)
            .controlSize(.large)

            // ── Last Recording box ───────────────────────────────────────────
            // Shown once a recording has been successfully saved.
            // Contains the filename, "Show in Finder", and the Transcribe button.
            if let url = engine.lastRecordingURL {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {

                        Label("Last Recording", systemImage: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Action buttons side by side
                        HStack(spacing: 10) {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            .controlSize(.small)

                            // Transcribe button — disabled while a task is running.
                            Button {
                                Task { await transcription.transcribe(audioURL: url) }
                            } label: {
                                if transcription.isTranscribing {
                                    HStack(spacing: 5) {
                                        ProgressView().scaleEffect(0.7)
                                        Text("Transcribing…")
                                    }
                                } else {
                                    Label("Transcribe", systemImage: "text.bubble")
                                }
                            }
                            .controlSize(.small)
                            .disabled(transcription.isTranscribing)

                            // Cancel button — only visible while transcribing.
                            if transcription.isTranscribing {
                                Button("Cancel") { transcription.cancel() }
                                    .controlSize(.small)
                                    .foregroundStyle(.red)
                            }
                        }

                        // Transcription phase status (progress or error message)
                        if !transcription.status.isEmpty {
                            Text(transcription.status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 420)
            }

            // ── Transcript panel ─────────────────────────────────────────────
            // Appears after a successful transcription. Scrollable, selectable,
            // with Copy and "Show .txt file" actions.
            if !transcription.transcript.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {

                        // Header row
                        HStack {
                            Label("Transcript", systemImage: "text.quote")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()

                            // Copy to clipboard
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    transcription.transcript, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .controlSize(.small)

                            // Open the saved .txt file in Finder
                            if let txtURL = transcription.transcriptURL {
                                Button("Show file") {
                                    NSWorkspace.shared.activateFileViewerSelecting([txtURL])
                                }
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        // Scrollable transcript text — text selection enabled
                        // so the user can highlight + copy individual sentences.
                        ScrollView {
                            Text(transcription.transcript)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .frame(height: 220)
                    }
                }
                .frame(maxWidth: 420)
            }

            // ── Permission reminder ──────────────────────────────────────────
            Text("Requires Microphone, Screen Recording & Speech Recognition permissions\n(System Settings → Privacy & Security)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(36)
        .frame(minWidth: 520, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
