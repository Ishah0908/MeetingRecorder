# MeetingRecorder

A lightweight macOS app that records **both sides of any online meeting** — your microphone and the system audio (Zoom, Teams, Google Meet, or any other app) — and mixes them into a single clean WAV file.

---

## Why this exists

Most screen recorders capture one track or the other, or let you configure complex routing. MeetingRecorder does exactly one thing: press Start before your call, press Stop when you're done, get a properly mixed recording saved to `~/Documents/MeetingRecordings/`.

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

Grant both in **System Settings → Privacy & Security**.  
If you deny either, the app will show an error and stop gracefully.

---

## Output files

Recordings are saved to `~/Documents/MeetingRecordings/`:

```
meeting-2026-06-12T14-30-00Z.wav    ← the final mixed file you keep
```

Hidden temp files (`.meeting-*.mic.wav`, `.meeting-*.system.wav`) are deleted automatically after a successful mix. If mixing fails, the raw tracks are kept so no audio is lost.

---

## Project structure

```
MeetingRecorder/
├── MeetingRecorder.xcodeproj/
├── project.yml                     ← XcodeGen spec (optional, for regenerating the project)
└── MeetingRecorder/
    ├── MeetingRecorderApp.swift    ← App entry point, window configuration
    ├── ContentView.swift           ← Single-screen UI (SwiftUI)
    ├── AudioCaptureEngine.swift    ← All recording logic (ScreenCaptureKit + AVAudioEngine)
    ├── MeetingRecorder.entitlements
    └── Info.plist
```

---

## Author

Ibrahim Sultan — [github.com/Ishah0908](https://github.com/Ishah0908)
