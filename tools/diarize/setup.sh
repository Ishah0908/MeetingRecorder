#!/usr/bin/env bash
#
# One-time setup for the speaker-diarization tool.
# Creates a local Python virtual environment (.venv) and installs WhisperX.
#
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install Python 3.9+ first (e.g. brew install python)." >&2
  exit 1
fi

echo "Creating virtual environment (.venv)…"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate

echo "Upgrading pip…"
pip install --upgrade pip >/dev/null

echo "Installing WhisperX (downloads PyTorch + pyannote — this can be a few GB)…"
pip install -r requirements.txt

cat <<'EOF'

✓ Setup complete.

Next steps (one time):
  1. Create a free Hugging Face token:
       https://huggingface.co/settings/tokens
  2. Accept the model terms (click "Agree"):
       https://huggingface.co/pyannote/speaker-diarization-3.1
  3. Save the token next to the script:
       echo 'hf_xxxxxxxx' > "$(pwd)/.hf_token"

Then either run it directly:
    .venv/bin/python diarize.py ~/Documents/MeetingRecordings/meeting-XXXX.wav
or click "Identify speakers" in the MeetingRecorder app and point it at diarize.py.
EOF
