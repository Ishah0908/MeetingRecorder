//
//  ContentView.swift
//  MeetingRecorder
//
//  Main (and only) screen of the app. Connects the UI to `AudioCaptureEngine`
//  via `@StateObject` so every published state change automatically refreshes
//  the view.
//
//  Layout (top → bottom):
//    1. Animated recording indicator  — pulsing red circle while recording
//    2. Status label                  — engine.statusMessage keeps users informed
//    3. Start / Stop button           — toggles engine.startRecording / stopRecording
//    4. Last saved file box           — shows filename + "Show in Finder" when available
//    5. Permission reminder           — non-blocking hint about required privacy grants
//
//  Author : Ibrahim Sultan
//  Requires: macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//

import SwiftUI

/// Primary view. All recording logic lives in `AudioCaptureEngine`;
/// this view only handles presentation and user interaction.
struct ContentView: View {

    /// Single engine instance, retained for the lifetime of the view.
    @StateObject private var engine = AudioCaptureEngine()

    /// Drives the pulsing animation on the recording indicator.
    /// Toggled in `onChange(of: engine.isRecording)` rather than inside the
    /// animation modifier, which avoids a timing edge-case on rapid taps.
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {

            // ── Recording indicator ──────────────────────────────────────────
            // Outer ring pulses (scale 1.0 → 1.4) while recording.
            // Inner dot is red while recording, grey while idle.
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
            // Sync pulse state whenever recording starts or stops.
            .onChange(of: engine.isRecording) { _, recording in
                pulse = recording
            }

            // ── Status text ──────────────────────────────────────────────────
            // Reflects the engine's current phase: Idle / Recording / Mixing / Saved.
            Text(engine.statusMessage)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            // ── Start / Stop button ──────────────────────────────────────────
            // Calls async engine methods inside a Task so the button doesn't
            // block the main thread while ScreenCaptureKit or AVAudioEngine spins up.
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

            // ── Last saved file ──────────────────────────────────────────────
            // Shown only after a successful recording + mix completes.
            // "Show in Finder" reveals the mixed WAV file in a Finder window.
            if let url = engine.lastRecordingURL {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Last Recording", systemImage: "waveform")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 340)
            }

            // ── Permission hint ──────────────────────────────────────────────
            // Displayed permanently as a reminder; the OS enforces the grants.
            Text("Requires Microphone + Screen Recording permissions\n(System Settings → Privacy & Security)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 380)
    }
}

#Preview {
    ContentView()
}
