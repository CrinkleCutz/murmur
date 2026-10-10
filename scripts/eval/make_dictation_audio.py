#!/usr/bin/env python3
"""Voices scripts/eval/dictation_corpus.py with Deepgram Aura-2 (key from the Keychain item "deepgram-api-key", never
printed) and writes two versions of every clip into OUT (default build/eval-audio, gitignored):
  clean/<voice>_<id>.wav  — Deepgram's audio at 16 kHz mono + the key held after speaking
  room/<voice>_<id>.wav   — the same through a laptop-in-a-room chain: 90 Hz–7 kHz band, early reflections,
                            pink noise ~35 dB under the speech, level varied per clip
Existing files are kept, so re-running only voices what is missing."""
import json, os, subprocess, sys, urllib.request, random, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dictation_corpus import ITEMS, VOICES
OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "../../build/eval-audio"))
for d in ("mp3", "clean", "room"): os.makedirs(os.path.join(OUT, d), exist_ok=True)
key = subprocess.check_output(["security", "find-generic-password", "-s", "deepgram-api-key", "-w"]).decode().strip()
def ff(*args): subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *args], check=True)
for voice, model in VOICES.items():
    for cid, (spoken, _) in ITEMS.items():
        name = f"{voice}_{cid}"
        mp3, clean, room = (os.path.join(OUT, d, f"{name}.{e}") for d, e in (("mp3", "mp3"), ("clean", "wav"), ("room", "wav")))
        if not os.path.exists(mp3):
            req = urllib.request.Request(f"https://api.deepgram.com/v1/speak?model={model}", data=json.dumps({"text": spoken}).encode(),
                                         headers={"Authorization": f"Token {key}", "Content-Type": "application/json"})
            open(mp3, "wb").write(urllib.request.urlopen(req).read())
        hold = 3.0 if cid.startswith("l_") else 1.2          # key still held after the last word
        if not os.path.exists(clean):
            ff("-i", mp3, "-af", f"adelay=300,apad=pad_dur={hold}", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", clean)
        if not os.path.exists(room):
            rnd = random.Random(int(hashlib.md5(name.encode()).hexdigest(), 16))
            gain = rnd.uniform(-9, -1)
            ff("-i", clean, "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.012:sample_rate=16000",
               "-filter_complex",
               f"[0]highpass=f=90,lowpass=f=7000,aecho=0.8:0.55:19|37|61:0.22|0.12|0.06,volume={gain:.1f}dB[s];"
               f"[1]volume={gain:.1f}dB[n];[s][n]amix=inputs=2:duration=first:normalize=0",
               "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", room)
        print(name, flush=True)
