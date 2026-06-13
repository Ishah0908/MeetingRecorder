//
//  DiarizationRunner.swift
//  MeetingRecorder
//
//  Runs the optional, local speaker-diarization tool (tools/diarize/diarize.py)
//  over a finished recording and reports progress to the UI.
//
//  This is the "advanced, who-said-what" path: it splits the call into
//  individual speakers using WhisperX + pyannote, which run in Python on the
//  CPU. The app shells out to that script rather than bundling a Python runtime,
//  so this feature degrades gracefully — if the tool isn't set up yet, the UI
//  points the user at the one-time setup instead of failing silently.
//
//  The app is NOT sandboxed (see entitlements), so spawning a process and
//  reading/writing files in ~/Documents works without security-scoped bookmarks.
//
//  Author: Ibrahim Sultan
//

import Foundation
import AppKit

/// Observable wrapper around the external diarization script.
@MainActor
final class DiarizationRunner: ObservableObject {

    /// `true` while the Python process is running.
    @Published var isRunning = false

    /// Latest progress line from the tool (e.g. "[2/4] Transcribing…").
    @Published var status = ""

    /// URL of the produced `.diarized.txt`, set on success.
    @Published var outputURL: URL?

    /// User-facing error message, set on failure.
    @Published var lastError: String?

    /// UserDefaults key storing the located path to `diarize.py`.
    private let scriptKey = "diarizeScriptPath"

    private var process: Process?

    // MARK: - Configuration state

    /// Absolute path to the located `diarize.py`, persisted across launches.
    var scriptPath: String? {
        get { UserDefaults.standard.string(forKey: scriptKey) }
        set { UserDefaults.standard.set(newValue, forKey: scriptKey) }
    }

    /// The virtual-env Python interpreter that lives beside the script
    /// (`<scriptDir>/.venv/bin/python`), created by `setup.sh`.
    private var venvPython: URL? {
        guard let scriptPath else { return nil }
        let dir = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()
        return dir.appendingPathComponent(".venv/bin/python")
    }

    /// `true` once the script has been located.
    var isConfigured: Bool {
        guard let scriptPath else { return false }
        return FileManager.default.fileExists(atPath: scriptPath)
    }

    /// `true` when both the script and its virtual environment exist, i.e. the
    /// tool is ready to run.
    var isReady: Bool {
        guard isConfigured, let python = venvPython else { return false }
        return FileManager.default.fileExists(atPath: python.path)
    }

    // MARK: - Locating the script

    /// Present an open panel so the user can point the app at `diarize.py`.
    func locateScript() {
        let panel = NSOpenPanel()
        panel.title = "Locate diarize.py"
        panel.message = "Select diarize.py inside the project's tools/diarize folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
            objectWillChange.send()
            status = isReady
                ? "Tool ready."
                : "Located, but the Python environment is missing — run setup.sh."
        }
    }

    // MARK: - Running

    /// Run diarization on `audioURL`. Streams progress into `status`; on success
    /// sets `outputURL` to the produced transcript.
    ///
    /// - Parameters:
    ///   - audioURL: The mixed WAV to analyse.
    ///   - language: Transcription language; only the base code (en/es) is passed.
    func run(audioURL: URL, language: TranscriptionLanguage) {
        guard !isRunning else { return }
        guard let scriptPath, FileManager.default.fileExists(atPath: scriptPath) else {
            lastError = "Diarization tool not located. Click \u{201C}Identify speakers\u{201D} to set it up."
            return
        }
        guard let python = venvPython, FileManager.default.fileExists(atPath: python.path) else {
            lastError = "Python environment not found. Run setup.sh in tools/diarize first."
            return
        }

        isRunning = true
        lastError = nil
        outputURL = nil
        status = "Starting… (first run downloads models, please wait)"

        let output = audioURL.deletingPathExtension().appendingPathExtension("diarized.txt")
        let langCode = String(language.rawValue.prefix(2))   // "en-US" -> "en"

        let proc = Process()
        proc.executableURL = python
        proc.arguments = [scriptPath, audioURL.path, "--output", output.path, "--language", langCode]

        // Merge stdout + stderr so progress and errors both reach the UI.
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            let line = chunk
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            if let line {
                Task { @MainActor in self.status = line }
            }
        }

        proc.terminationHandler = { finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self.isRunning = false
                self.process = nil
                if finished.terminationStatus == 0 {
                    self.outputURL = output
                    self.status = "Done — \(output.lastPathComponent)"
                } else {
                    self.lastError = self.status.isEmpty
                        ? "Diarization failed (exit code \(finished.terminationStatus))."
                        : self.status
                    self.status = "Failed."
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            isRunning = false
            lastError = "Couldn't start diarization: \(error.localizedDescription)"
        }
    }

    /// Cancel a running diarization.
    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
        status = "Cancelled."
    }
}
