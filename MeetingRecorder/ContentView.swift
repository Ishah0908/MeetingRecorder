//
//  ContentView.swift
//  MeetingRecorder
//
//  Main screen of the app. Binds the UI to two observable engines:
//    • AudioCaptureEngine  — manages the recording lifecycle
//    • TranscriptionEngine — live + file-based transcription
//
//  When you press Start, the app begins recording AND live transcription at the
//  same time. The mic stream is labeled "You" and the system-audio stream is
//  labeled "Others", so the transcript separates the two sides of the call as
//  text appears. On Stop, the interleaved transcript is saved as a .txt beside
//  the WAV.
//
//  Author : Ibrahim Sultan
//  Requires: macOS 15 (Sequoia) · Xcode 16 · Swift 5.10
//

import SwiftUI

/// Primary view. All recording/transcription logic lives in the engines;
/// this view handles only presentation and user interaction.
struct ContentView: View {

    /// Manages the full recording lifecycle (capture → mix → save).
    @StateObject private var engine = AudioCaptureEngine()

    /// Manages live + file-based transcription.
    @StateObject private var transcription = TranscriptionEngine()

    /// Runs the optional local speaker-diarization tool.
    @StateObject private var diarizer = DiarizationRunner()

    /// Drives the pulsing animation on the recording indicator.
    @State private var pulse = false

    /// Controls the diarization setup/help sheet.
    @State private var showDiarizeInfo = false

    /// True when there is any transcript content to show (live or finished).
    private var hasTranscriptContent: Bool {
        transcription.isLive
            || !transcription.segments.isEmpty
            || !transcription.livePartialYou.isEmpty
            || !transcription.livePartialOthers.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {

            recordingIndicator

            Text(engine.statusMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            startStopButton

            if hasTranscriptContent {
                transcriptPanel
            }

            if let url = engine.lastRecordingURL {
                lastRecordingBox(url: url)
            }

            Text("Requires Microphone, Screen Recording & Speech Recognition permissions\n(System Settings → Privacy & Security)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 520)
    }

    // MARK: - Recording indicator

    /// Pulsing red circle while recording; grey dot while idle.
    private var recordingIndicator: some View {
        ZStack {
            Circle()
                .fill(engine.isRecording ? Color.red.opacity(0.15) : Color.clear)
                .frame(width: 60, height: 60)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .animation(
                    engine.isRecording
                        ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
            Circle()
                .fill(engine.isRecording ? Color.red : Color.gray.opacity(0.4))
                .frame(width: 26, height: 26)
        }
        .onChange(of: engine.isRecording) { _, recording in
            pulse = recording
        }
    }

    // MARK: - Start / Stop

    /// Toggles recording + live transcription together.
    private var startStopButton: some View {
        Button {
            Task {
                if engine.isRecording {
                    // Stop recording first so lastRecordingURL is set, then
                    // stop live transcription and save the .txt beside the WAV.
                    await engine.stopRecording()
                    engine.onMicBuffer = nil
                    engine.onSystemBuffer = nil
                    await transcription.stopLive(besideAudio: engine.lastRecordingURL)
                } else {
                    // Set up live transcription, wire the audio taps, then record.
                    await transcription.startLive()
                    engine.onMicBuffer = { [transcription] buf in transcription.appendYou(buf) }
                    engine.onSystemBuffer = { [transcription] buf in transcription.appendOthers(buf) }
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
    }

    // MARK: - Live transcript panel

    /// Scrollable, color-coded transcript that updates live while recording.
    /// "You" (mic) is blue, "Others" (system audio) is green. The most recent
    /// in-progress text for each source shows at the bottom in a lighter tone.
    private var transcriptPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {

                // Header with live badge + actions.
                HStack {
                    Label("Transcript", systemImage: "text.quote")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if transcription.isLive {
                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 7, height: 7)
                            Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    Button {
                        let text = transcription.transcript.isEmpty
                            ? assembledLiveText()
                            : transcription.transcript
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)

                    if let txtURL = transcription.transcriptURL {
                        Button("Show file") {
                            NSWorkspace.shared.activateFileViewerSelecting([txtURL])
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                // Scrolling list of finalized segments + live partials, pinned
                // to the bottom so new text stays visible.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(transcription.segments) { seg in
                                segmentRow(speaker: seg.speaker, text: seg.text, faded: false)
                            }
                            if !transcription.livePartialYou.isEmpty {
                                segmentRow(speaker: "You", text: transcription.livePartialYou, faded: true)
                            }
                            if !transcription.livePartialOthers.isEmpty {
                                segmentRow(speaker: "Others", text: transcription.livePartialOthers, faded: true)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(height: 240)
                    .onChange(of: transcription.segments.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: transcription.livePartialYou) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: transcription.livePartialOthers) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                if !transcription.status.isEmpty {
                    Text(transcription.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 460)
    }

    /// One transcript line: a colored speaker tag followed by the text.
    private func segmentRow(speaker: String, text: String, faded: Bool) -> some View {
        let color: Color = speaker == "You" ? .blue : .green
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 54, alignment: .leading)
            Text(text)
                .font(.callout)
                .foregroundStyle(faded ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Assemble the current live segments into plain text (used by Copy before
    /// the final transcript has been built on Stop).
    private func assembledLiveText() -> String {
        transcription.assembledTranscript()
    }

    // MARK: - Last recording box

    /// Shows the saved WAV with Finder access and a file-based re-transcribe
    /// option (useful if live transcription wasn't available).
    private func lastRecordingBox(url: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Last Recording", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)

                    Button {
                        Task { await transcription.transcribe(audioURL: url) }
                    } label: {
                        if transcription.isTranscribing {
                            HStack(spacing: 5) {
                                ProgressView().scaleEffect(0.7)
                                Text("Transcribing…")
                            }
                        } else {
                            Label("Re-transcribe file", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(transcription.isTranscribing || engine.isRecording)

                    if transcription.isTranscribing {
                        Button("Cancel") { transcription.cancel() }
                            .controlSize(.small)
                            .foregroundStyle(.red)
                    }
                }

                // Advanced: split "Others" into individual speakers via the
                // optional local WhisperX/pyannote tool. Opens setup if needed.
                HStack(spacing: 10) {
                    Button {
                        if diarizer.isReady {
                            diarizer.run(audioURL: url)
                        } else {
                            showDiarizeInfo = true
                        }
                    } label: {
                        if diarizer.isRunning {
                            HStack(spacing: 5) {
                                ProgressView().scaleEffect(0.7)
                                Text("Identifying speakers…")
                            }
                        } else {
                            Label("Identify speakers", systemImage: "person.2.wave.2")
                        }
                    }
                    .controlSize(.small)
                    .disabled(diarizer.isRunning || engine.isRecording)

                    if diarizer.isRunning {
                        Button("Cancel") { diarizer.cancel() }
                            .controlSize(.small)
                            .foregroundStyle(.red)
                    }

                    if let out = diarizer.outputURL {
                        Button("Show speaker transcript") {
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                        }
                        .controlSize(.small)
                    }
                }

                if diarizer.isRunning, !diarizer.status.isEmpty {
                    Text(diarizer.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let err = diarizer.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 460)
        .sheet(isPresented: $showDiarizeInfo) { diarizeSetupSheet }
    }

    // MARK: - Diarization setup sheet

    /// One-time setup / help for the optional speaker-identification tool.
    private var diarizeSetupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Identify individual speakers")
                .font(.title3.bold())

            Text("Splits the “Others” side of a call into Speaker 1, Speaker 2, … using a free, on-device model (WhisperX + pyannote). It runs after the meeting, not live, and takes a few minutes on a Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("One-time setup")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Label("In Terminal, run ./setup.sh inside the project's tools/diarize folder.", systemImage: "1.circle")
                Label("Get a free Hugging Face token and accept the pyannote model terms.", systemImage: "2.circle")
                Label("Save the token to tools/diarize/.hf_token", systemImage: "3.circle")
                Label("Click “Locate diarize.py…” below and pick the script.", systemImage: "4.circle")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if let path = diarizer.scriptPath {
                Text(diarizer.isReady ? "✓ Ready: \(path)" : "Located, but run setup.sh: \(path)")
                    .font(.caption)
                    .foregroundStyle(diarizer.isReady ? .green : .orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Locate diarize.py…") { diarizer.locateScript() }
                Spacer()
                Button("Done") { showDiarizeInfo = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}

#Preview {
    ContentView()
}
