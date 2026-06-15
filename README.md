# MeetingRecorder

A lightweight macOS app that records **both sides of any online meeting** — your microphone and the system audio (Zoom, Teams, Google Meet, or any other app) — and mixes them into a single clean WAV file.

---

## Why this exists

Most screen recorders capture one track or the other, or let you configure complex routing. MeetingRecorder does exactly two things: press Start before your call, press Stop when you're done — you get a properly mixed WAV in `~/Documents/MeetingRecordings/` **and a live, speaker-labeled transcript** that writes itself as people talk, saved as a `.txt` beside the recording.

---

## How it works

### Two sources, two temp files, one mix

```
Microphone  ──►  AVAudioEngine tap  ──►  .mic.wav  (temp, hidden)
                                                              ├──► mix()  ──►  meeting-<stamp>.wav
System audio ──►  ScreenCaptureKit  ──►  .system.wav (temp, hidden)
```

The naive approach of writing both sources into the same `AVAudioFile` as buffers arrive produces **interleaved chunks, not a mix** — the result is garbled audio roughly twice as long as expected. This app avoids that by:

1. Recording each source to its own hidden temp file simultaneously.
2. When you press Stop, summing the two tracks **sample-by-sample** into the final output file.
3. Deleting the temp files.

The shorter track is zero-padded so both tracks contribute for the full duration.  
The sum is hard-clipped to ±1.0 to prevent digital overs.

### Audio pipeline

| Source | Framework | Format |
|--------|-----------|--------|
| System audio (call / everyone else) | ScreenCaptureKit | Captured pre-output, converted to Float32 48 kHz mono |
| Microphone (your voice) | AVAudioEngine | Tapped at native input format, converted to Float32 48 kHz mono |

Both streams are converted to the same `AVAudioFormat` (Float32, 48 kHz, 1 channel) before writing, so the mix step is a straightforward sample loop with no resampling needed.

---

## Requirements

| | |
|---|---|
| **macOS** | 15 (Sequoia) or later |
| **Xcode** | 16 or later |
| **Swift** | 5.10 |

---

## Build & Run

```bash
# Clone the repo
git clone https://github.com/Ishah0908/MeetingRecorder.git
cd MeetingRecorder

# Open in Xcode
open MeetingRecorder.xcodeproj
```

Then **Product → Run** (⌘R). No external dependencies.

> **Note:** The project is set up for local builds (`CODE_SIGNING_REQUIRED = NO`).  
> For distribution, set your Team ID in the project's Signing settings.

---

## Permissions

On first launch macOS will prompt for:

| Permission | Why it's needed |
|------------|----------------|
| **Microphone** | To capture your voice via AVAudioEngine |
| **Screen Recording** | ScreenCaptureKit requires this to access system audio — even though no screen pixels are ever captured |
| **Speech Recognition** | Required to transcribe recordings to text via `SFSpeechRecognizer` |

Grant all three in **System Settings → Privacy & Security**.  
If you deny either, the app will show an error and stop gracefully.

---

## Output files

Recordings are saved to `~/Documents/MeetingRecordings/`:

```
meeting-2026-06-12T14-30-00Z.wav    ← the final mixed file you keep
meeting-2026-06-12T14-30-00Z.txt    ← transcript (created when you click Transcribe)
```

Hidden temp files (`.meeting-*.mic.wav`, `.meeting-*.system.wav`) are deleted automatically after a successful mix. If mixing fails, the raw tracks are kept so no audio is lost.

### Transcription

Transcription runs in two ways:

**Live (primary).** The moment you press Start, speech recognition runs alongside the recording and text appears on screen as people speak. Because the app already captures two separate sources, it labels their output:

| Tag | Source | Who it is |
|-----|--------|-----------|
| 🔵 **You** | Microphone | Your own voice |
| 🟢 **Others** | System audio | Everyone else on the call |

A dated transcript file (`meeting-<stamp>.txt`) is created in `~/Documents/MeetingRecordings/` the instant you press Start, and **every recognized line is appended to it as it happens.** The full meeting is therefore on disk the entire time — nothing is lost no matter how long the call runs or how much scrolls off the screen. Use the **Show file** button in the transcript panel to reveal it in Finder at any point, even mid-recording. On Stop the file is simply flushed and closed.

**File (fallback).** A **Re-transcribe file** button runs `SFSpeechURLRecognitionRequest` on the finished mix — useful if live transcription wasn't available (e.g. permission was granted after recording started).

#### A note on speaker identification

Apple's Speech framework has **no built-in speaker diarization** — you can't get "Speaker 1 / Speaker 2" labels out of a single mixed stream. The **You / Others** split above works because the two sides of the call are captured as physically separate audio streams.

Telling apart *individual remote participants* from one another (within the system audio) needs a real diarization model. That's available here as an **optional, free, local** tool — see [Identifying individual speakers](#identifying-individual-speakers-advanced) below.

Live recognition prefers **on-device** transcription (`requiresOnDeviceRecognition`) so it runs continuously for long meetings and works offline.

#### Identifying individual speakers (advanced)

The **Identify speakers** button under the last recording runs an optional local tool ([`tools/diarize/`](tools/diarize/)) that uses [WhisperX](https://github.com/m-bain/whisperX) + [pyannote](https://github.com/pyannote/pyannote-audio) to split the call into Speaker 1 / Speaker 2 / … and writes a `*.diarized.txt`. It's free and runs entirely on your Mac (CPU), so it works **after** the meeting rather than live, and takes a few minutes.

It needs a one-time setup (a Python venv + a free Hugging Face token). The first time you click the button the app walks you through it; full details are in [`tools/diarize/README.md`](tools/diarize/README.md).

#### Languages

Live transcription is **English**. Apple's `SFSpeechRecognizer` is locale-locked and can't auto-detect a language; running an English and a Spanish recognizer on the same stream in parallel was tried and produced duplicate, garbled lines, so it was removed in favor of clean, reliable English.

For **other languages and translation**, use the offline diarize tool ([`tools/diarize/`](tools/diarize/)): Whisper genuinely auto-detects the spoken language, and `diarize.py --translate` writes an all-English transcript regardless of what was spoken. It runs on a saved recording rather than live.

---

## Troubleshooting

### "It keeps asking for permission / the Settings prompt loops"

This happens when the app is **ad-hoc signed**. Ad-hoc signatures change on every rebuild, so macOS treats each build as a new app and forgets the Screen Recording / Speech / Microphone grant — re-prompting forever.

The project is configured to sign with a stable **Apple Development** identity (`CODE_SIGN_IDENTITY` in `project.yml`), which fixes this: the permission grant persists across rebuilds. If you fork this repo, set `CODE_SIGN_IDENTITY` to your own identity (find it with `security find-identity -v -p codesigning`).

If you previously ran an ad-hoc build and are still being re-prompted, clear the stale grants once:

```bash
tccutil reset ScreenCapture com.meetingrecorder.app
tccutil reset SpeechRecognition com.meetingrecorder.app
tccutil reset Microphone com.meetingrecorder.app
```

Then run the (properly signed) app and grant each permission a final time. After granting **Screen Recording**, macOS requires the app to be **quit and reopened** once.

---

## Project structure

```
MeetingRecorder/
├── MeetingRecorder.xcodeproj/
├── project.yml                     ← XcodeGen spec (optional, for regenerating the project)
├── tools/
│   └── diarize/                    ← Optional local speaker-diarization tool (Python)
│       ├── diarize.py              ← WhisperX + pyannote → speaker-labeled transcript
│       ├── requirements.txt
│       ├── setup.sh                ← One-time venv + dependency install
│       └── README.md
└── MeetingRecorder/
    ├── MeetingRecorderApp.swift    ← App entry point, window configuration
    ├── ContentView.swift           ← Single-screen UI (SwiftUI)
    ├── AudioCaptureEngine.swift    ← Recording logic (ScreenCaptureKit + AVAudioEngine + mix)
    ├── TranscriptionEngine.swift   ← Live + file SFSpeechRecognizer wrapper (You/Others, multi-language)
    ├── DiarizationRunner.swift     ← Shells out to the optional diarization tool
    ├── MeetingRecorder.entitlements
    └── Info.plist
```

---

## Author

Ibrahim Sultan — [github.com/Ishah0908](https://github.com/Ishah0908)
