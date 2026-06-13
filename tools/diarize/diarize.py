#!/usr/bin/env python3
"""
diarize.py — Speaker diarization + transcription for MeetingRecorder.

Runs WhisperX (Whisper transcription + forced alignment + pyannote speaker
diarization) over a recording and writes a speaker-labeled transcript:

    [Speaker 1] (0:03) Hey, can everyone hear me?
    [Speaker 2] (0:07) Yep, loud and clear.

Everything runs locally and is free. The pyannote diarization model is gated on
Hugging Face, so a free HF access token is required the first time (only to
download the model). Provide it via --hf-token, the HF_TOKEN environment
variable, or a `.hf_token` file placed next to this script.

Usage:
    python diarize.py /path/to/meeting.wav
    python diarize.py meeting.wav --output meeting.diarized.txt --language en --model small

This is the "advanced, who-said-what" companion to the app's live You/Others
view. It runs AFTER a meeting, not live — diarization needs the whole file.

Author: Ibrahim Sultan
"""

import argparse
import os
import sys
from pathlib import Path


def load_hf_token(cli_token):
    """Resolve the Hugging Face token from CLI arg, env, or a .hf_token file."""
    if cli_token:
        return cli_token
    env = os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")
    if env:
        return env
    token_file = Path(__file__).with_name(".hf_token")
    if token_file.exists():
        return token_file.read_text(encoding="utf-8").strip()
    return None


def fmt_ts(seconds):
    """Format a timestamp in seconds as M:SS (or H:MM:SS for long meetings)."""
    seconds = int(seconds or 0)
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"


def main():
    parser = argparse.ArgumentParser(
        description="Speaker-diarized transcription via WhisperX (local, free)."
    )
    parser.add_argument("audio", help="Path to the recording (WAV/M4A/etc.)")
    parser.add_argument("--output", help="Output .txt path (default: <audio>.diarized.txt)")
    parser.add_argument("--model", default="small",
                        help="Whisper model size: tiny/base/small/medium/large-v3 (default: small)")
    parser.add_argument("--language", default=None,
                        help="Language code (en, es, …). Auto-detected if omitted.")
    parser.add_argument("--hf-token", dest="hf_token", default=None,
                        help="Hugging Face access token (for the gated pyannote model).")
    parser.add_argument("--min-speakers", type=int, default=None,
                        help="Hint: minimum number of speakers.")
    parser.add_argument("--max-speakers", type=int, default=None,
                        help="Hint: maximum number of speakers.")
    args = parser.parse_args()

    audio_path = Path(args.audio).expanduser()
    if not audio_path.exists():
        print(f"ERROR: file not found: {audio_path}", file=sys.stderr)
        sys.exit(2)

    hf_token = load_hf_token(args.hf_token)
    if not hf_token:
        print(
            "ERROR: No Hugging Face token found. The diarization model is gated.\n"
            "  1. Create a free token: https://huggingface.co/settings/tokens\n"
            "  2. Accept the terms:    https://huggingface.co/pyannote/speaker-diarization-3.1\n"
            "  3. Provide it via --hf-token, the HF_TOKEN env var, or a .hf_token file\n"
            "     next to this script (e.g.  echo 'hf_xxx' > .hf_token ).",
            file=sys.stderr,
        )
        sys.exit(3)

    try:
        import whisperx
    except ImportError:
        print("ERROR: whisperx is not installed. Run ./setup.sh in this folder first.",
              file=sys.stderr)
        sys.exit(4)

    # Macs have no CUDA, so faster-whisper runs on the CPU. int8 is the fast,
    # low-memory CPU compute path.
    device = "cpu"
    compute_type = "int8"

    print(f"[1/4] Loading Whisper model '{args.model}' on CPU…", flush=True)
    audio = whisperx.load_audio(str(audio_path))
    model = whisperx.load_model(args.model, device, compute_type=compute_type,
                                language=args.language)

    print("[2/4] Transcribing…", flush=True)
    result = model.transcribe(audio, batch_size=16)
    language = result.get("language", args.language or "en")

    print("[3/4] Aligning words to audio…", flush=True)
    try:
        align_model, metadata = whisperx.load_align_model(language_code=language, device=device)
        result = whisperx.align(result["segments"], align_model, metadata, audio, device,
                                return_char_alignments=False)
    except Exception as exc:  # alignment is best-effort; diarization still works without it
        print(f"  (alignment skipped: {exc})", flush=True)

    print("[4/4] Diarizing speakers… (first run downloads the pyannote model)", flush=True)
    # The import path moved between WhisperX versions; support both.
    try:
        from whisperx import DiarizationPipeline
    except ImportError:
        from whisperx.diarize import DiarizationPipeline

    diarize_model = DiarizationPipeline(use_auth_token=hf_token, device=device)
    diarize_kwargs = {}
    if args.min_speakers is not None:
        diarize_kwargs["min_speakers"] = args.min_speakers
    if args.max_speakers is not None:
        diarize_kwargs["max_speakers"] = args.max_speakers
    diarize_segments = diarize_model(audio, **diarize_kwargs)
    result = whisperx.assign_word_speakers(diarize_segments, result)

    # Map pyannote's internal labels (SPEAKER_00, …) to friendly, stable numbers
    # in first-appearance order.
    speaker_label = {}

    def label_for(spk):
        if spk not in speaker_label:
            speaker_label[spk] = f"Speaker {len(speaker_label) + 1}"
        return speaker_label[spk]

    lines = []
    for seg in result.get("segments", []):
        text = (seg.get("text") or "").strip()
        if not text:
            continue
        spk = seg.get("speaker", "Unknown")
        label = label_for(spk) if spk != "Unknown" else "Unknown"
        lines.append(f"[{label}] ({fmt_ts(seg.get('start'))}) {text}")

    out_path = Path(args.output).expanduser() if args.output \
        else audio_path.with_suffix(".diarized.txt")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"\nDONE: {out_path}", flush=True)
    print(f"Speakers detected: {len(speaker_label)}", flush=True)


if __name__ == "__main__":
    main()
