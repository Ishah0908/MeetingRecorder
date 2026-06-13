# Speaker diarization tool

Optional, **free**, **local** companion to MeetingRecorder that splits a
recording into individual speakers — "who said what" — using
[WhisperX](https://github.com/m-bain/whisperX) (Whisper transcription +
[pyannote](https://github.com/pyannote/pyannote-audio) speaker diarization).

This complements the app's live **You / Others** view. Use this when you need to
tell individual *remote* participants apart (Speaker 1, Speaker 2, …). It runs
**after** a meeting, not live, because diarization needs the whole file.

## What it costs

Nothing. The library and models are open source and run on your Mac. The only
gate: the pyannote model is hosted on Hugging Face and needs a **free** access
token to download the first time.

Practical trade-offs: it's Python (not part of the Swift app), it runs on CPU on
Apple Silicon (so a long meeting takes minutes, not seconds), and the first run
downloads a few GB of models.

## Setup (one time)

```bash
cd tools/diarize
./setup.sh
```

Then get your token:

1. Create a free token: <https://huggingface.co/settings/tokens>
2. Accept the model terms: <https://huggingface.co/pyannote/speaker-diarization-3.1>
3. Save it next to the script:
   ```bash
   echo 'hf_xxxxxxxx' > tools/diarize/.hf_token
   ```

## Run it

Directly:

```bash
.venv/bin/python diarize.py ~/Documents/MeetingRecordings/meeting-XXXX.wav
```

Output is written next to the recording as `meeting-XXXX.diarized.txt`:

```
[Speaker 1] (0:03) Hey, can everyone hear me?
[Speaker 2] (0:07) Yep, loud and clear.
[Speaker 1] (0:11) Great, let's get started.
```

Useful flags:

| Flag | Purpose |
|------|---------|
| `--language en` | Skip auto-detect (also `es`, etc.) |
| `--model medium` | Bigger = more accurate, slower (`tiny`…`large-v3`) |
| `--min-speakers` / `--max-speakers` | Hint the speaker count |
| `--output path.txt` | Custom output location |

## From the app

In MeetingRecorder, click **Identify speakers** under the last recording. The
first time, it asks you to locate this `diarize.py`; after that it runs the tool
for you and reveals the result. (You still need `setup.sh` and a token done once.)
