#!/usr/bin/env python3
"""Scores recognition setups on the realistic dictation set (scripts/eval/make_dictation_audio.py) through the SAME
pipeline a live dictation takes up to the cleanup model (`--transcribe-list`: engines stay loaded, so times are warm).

    python3 scripts/eval/run_dictation_eval.py CONFIG [CONFIG ...] [--cond room|clean] [--app build/MurmurEval.app]
    python3 scripts/eval/run_dictation_eval.py --report

CONFIG names are in CONFIGS below. Results go to build/eval-results/<cond>/<config>.json; --report prints the table.
Headless: no windows, keys or clipboard."""
import json, os, re, subprocess, sys, statistics, time
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from dictation_corpus import ITEMS, VOICES
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
AUDIO = os.path.join(ROOT, "build/eval-audio"); RESULTS = os.path.join(ROOT, "build/eval-results")
CLAUDE, MAIL = "com.anthropic.claudefordesktop", "com.apple.mail"
WCPP = ["--engine", "whispercpp", "--whisper-model", "large-v3-turbo"]
CONFIGS = {  # name: (bundle id, engine args, extra environment)
 "wcpp-claude":        (CLAUDE, WCPP, {}),
 "wcpp-mail":          (MAIL, WCPP, {}),
 "wcpp-claude-beam5":  (CLAUDE, WCPP, {"MURMUR_WHISPERCPP_BEAM": "5"}),
 "wcpp-v3-claude":     (CLAUDE, ["--engine", "whispercpp", "--whisper-model", "large-v3"], {}),   # full Large v3 (not Turbo), 2026-09-30
 "wcpp-v3-claude-noprompt": (CLAUDE, ["--engine", "whispercpp", "--whisper-model", "large-v3"], {"MURMUR_WHISPERCPP_PROMPT": "none"}),
 "wcpp-claude-noprompt": (CLAUDE, WCPP, {"MURMUR_WHISPERCPP_PROMPT": "none"}),
 "wcpp-claude-nolead": (CLAUDE, WCPP, {"MURMUR_WHISPERCPP_LEADPAD_MS": "0"}),   # before 2026-09-29's 400 ms lead-in
 "distil35-claude": (CLAUDE, ["--engine", "whispercpp", "--whisper-model", "distil-large-v3.5"], {}),
 "wcpp-coreml-claude": (CLAUDE, ["--engine", "whispercpp", "--whisper-model", "large-v3-turbo-coreml"], {}),   # encoder on the Neural Engine
 # before 2026-09-29's unsure-word name fix (UnsureWordFix), which is now on by default
 "wcpp-claude-nonamefix": (CLAUDE, WCPP, {"MURMUR_NAMEFIX": "0"}),
 "pk2-mail-nonamefix": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX": "0"}),
 "pk2-mail":           (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {}),
 # Names on screen instead of in the vocabulary (2026-09-30): the fix gets no user words, the screen holds the measured
 # names + 24 real names from a Claude window (build/eval-results/screen_names.txt).
 "pk2-mail-screen":      (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX_USER_TERMS": "0", "MURMUR_SCREEN_NAMES_FILE": "build/eval-results/screen_names.txt"}),
 "pk2-mail-screen300": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX_USER_TERMS": "0", "MURMUR_SCREEN_NAMES_FILE": "build/eval-results/screen_names_300.txt"}),
 "pk2-mail-screen-big": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX_USER_TERMS": "0", "MURMUR_SCREEN_NAMES_FILE": "build/eval-results/screen_names_big.txt"}),
 "pk2-mail-screen-mixed": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_SCREEN_NAMES_FILE": "build/eval-results/screen_names_big.txt"}),   # as live: own words first, then the screen
 "pk2-mail-screen-same": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX_USER_TERMS": "0", "MURMUR_SCREEN_NAMES_FILE": "build/eval-results/screen_names.txt"}),
 "pk3-mail":           (MAIL, ["--engine", "parakeet", "--whisper-model", "v3"], {}),
 "pk-claude":          (CLAUDE, ["--engine", "parakeet", "--whisper-model", "v2"], {}),
 "pk-claude-fluid":    (CLAUDE, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_PARAKEET_VOCAB": "2.8,-2.2,0.72,0.64"}),
 "pk-mail-boost":      (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_PARAKEET_BOOST_ALL": "1"}),
 "pk-mail-boost-fluid": (MAIL, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_PARAKEET_BOOST_ALL": "1", "MURMUR_PARAKEET_VOCAB": "2.8,-2.2,0.72,0.64"}),
 "apple-mail":         (MAIL, ["--engine", "apple"], {}),
 # every engine with the unsure-word name fix (on by default) against the same engine without it
 "apple-mail-nonamefix": (MAIL, ["--engine", "apple"], {"MURMUR_NAMEFIX": "0"}),
 "wk-mail":            (MAIL, ["--engine", "whisper", "--whisper-model", "distil-whisper_distil-large-v3_turbo"], {}),
 "wk-mail-nonamefix":  (MAIL, ["--engine", "whisper", "--whisper-model", "distil-whisper_distil-large-v3_turbo"], {"MURMUR_NAMEFIX": "0"}),
 "nemo-mail":          (MAIL, ["--engine", "parakeet", "--whisper-model", "nemotron"], {}),
 "nemo-mail-nonamefix": (MAIL, ["--engine", "parakeet", "--whisper-model", "nemotron"], {"MURMUR_NAMEFIX": "0"}),
 "pk-claude-nonamefix": (CLAUDE, ["--engine", "parakeet", "--whisper-model", "v2"], {"MURMUR_NAMEFIX": "0"}),
 # transcribe while you talk (--chunked replays the recording through the live LiveChunkSession)
 "wcpp-claude-chunked":  (CLAUDE, WCPP + ["--chunked"], {}),
 "wcpp-claude-chunked8": (CLAUDE, WCPP + ["--chunked"], {"MURMUR_CHUNK_MIN": "8"}),   # more cuts, to stress the seams
}
TERMS = ["Stripe", "Wispr Flow", "superwhisper", "GitHub", "Newsreader", "Manrope", "Mac", "Claude Code", "Supabase", "Vercel",
         "Codex", "DMG", "VoiceInk", "HUD", "Murmur", "Deepgram", "Parakeet", "whisper.cpp", "Flit"]
XL = [("l_research", "l_banner"), ("l_navbar", "l_copy")]   # joined: past Whisper's 30-second window

def clips(cond):
    out = {}
    for v in VOICES:
        for cid, (_, ref) in ITEMS.items():
            out[f"{v}_{cid}"] = (os.path.join(AUDIO, cond, f"{v}_{cid}.wav"), ref)
        for a, b in XL:
            path = os.path.join(AUDIO, cond, f"{v}_xl_{a}+{b}.wav")
            if not os.path.exists(path):   # A's speech, a short pause, then B with its held key
                subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", os.path.join(AUDIO, cond, f"{v}_{a}.wav"),
                                "-i", os.path.join(AUDIO, cond, f"{v}_{b}.wav"), "-filter_complex",
                                "[0]silenceremove=stop_periods=-1:stop_duration=1:stop_threshold=-50dB[a];[a][1]concat=n=2:v=0:a=1",
                                "-ar", "48000" if cond.endswith("48") else "16000", "-ac", "1",
                                "-c:a", "pcm_f32le" if cond.endswith("48") else "pcm_s16le", path], check=True)
            out[f"{v}_xl_{a}+{b}"] = (path, ITEMS[a][1] + " " + ITEMS[b][1])
    return out

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
def say(n):
    n = int(n)
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    return say(n // 100) + " hundred" + ("" if n % 100 == 0 else " " + say(n % 100))
def norm(s):
    s = s.lower().replace("-", " ").replace("/", " ").replace("okay", "ok")
    s = re.sub(r"(\d+)\s*(am|pm)\b", r"\1 \2", s)
    s = re.sub(r"(\d+):(\d+)", r"\1 \2", s)
    s = re.sub(r"[^\w\s']", " ", s.replace(".cpp", "cpp"))
    s = re.sub(r"\b\d+\b", lambda m: say(m.group()) if int(m.group()) < 1000 else m.group(), s)
    return s.split()
def edits(a, b):
    dp = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, len(b) + 1):
            cur = min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] != b[j - 1])); prev, dp[j] = dp[j], cur
    return dp[len(b)]

def run(name, cond, app):
    bundle, args, env = CONFIGS[name]
    cs = clips(cond)
    lst = os.path.join(RESULTS, cond, f"{name}.list"); os.makedirs(os.path.dirname(lst), exist_ok=True)
    open(lst, "w").write("\n".join(p for p, _ in cs.values()))
    t = time.time()
    p = subprocess.run([os.path.join(app, "Contents/MacOS/Murmur"), "--transcribe-list", lst, *args, "--bundle-id", bundle],
                       capture_output=True, text=True, env=dict(os.environ, **env), timeout=3600)
    by_path, cur = {}, None
    for line in p.stdout.splitlines():
        if line.startswith("FILE: "): cur = by_path.setdefault(line[6:], {})
        elif cur is not None:
            for key in ("RAW", "FORMATTED", "TIMING", "FAILED", "CHUNKS"):
                if line.startswith(key + ": "): cur[key] = line[len(key) + 2:]
    res = {}
    for cid, (path, ref) in cs.items():
        r = by_path.get(path, {})
        res[cid] = {"ref": ref, "raw": r.get("RAW", ""), "fmt": r.get("FORMATTED", ""), "timing": r.get("TIMING", ""), "failed": r.get("FAILED"), "chunks": r.get("CHUNKS")}
    json.dump(res, open(os.path.join(RESULTS, cond, f"{name}.json"), "w"), indent=1, ensure_ascii=False)
    print(f"{name} [{cond}] done in {time.time() - t:.0f}s, {sum(1 for r in res.values() if r['failed'] or not r['fmt'])} empty/failed", flush=True)

def score(res):
    agg = {k: [0, 0] for k in ("all", "native", "accented", "short", "long")}
    terms = [0, 0]; punct = 0; ms = {"short": [], "medium": [], "long": [], "xl": []}
    native = {"asteria", "zeus", "draco"}
    for cid, r in res.items():
        voice, item = cid.split("_", 1)
        ref, hyp = norm(r["ref"]), norm(r["fmt"])
        e = edits(ref, hyp)
        kind = "xl" if item.startswith("xl_") else {"s": "short", "m": "medium", "l": "long"}[item[0]]
        for k in ("all", "native" if voice in native else "accented", "short" if kind == "short" else ("long" if kind in ("long", "xl") else None)):
            if k: agg[k][0] += e; agg[k][1] += len(ref)
        for term in TERMS:
            n = len(re.findall(r"(?<![\w.])" + re.escape(term) + r"(?![\w])", r["ref"]))
            if n: terms[1] += n; terms[0] += min(n, len(re.findall(r"(?<![\w.])" + re.escape(term) + r"(?![\w])", r["fmt"])))
        punct += abs(len(re.findall(r"[.?!:]", r["fmt"])) - len(re.findall(r"[.?!:]", r["ref"]))) + abs(r["fmt"].count(",") - r["ref"].count(","))
        m = re.findall(r"(vad\+trim|asr)=(\d+)", r["timing"])
        if m: ms[kind].append(sum(int(v) for _, v in m))
    w = {k: 100 * v[0] / max(1, v[1]) for k, v in agg.items()}
    return w, terms, punct / max(1, len(res)), {k: (int(statistics.median(v)) if v else None) for k, v in ms.items()}

def report():
    for cond in sorted(d for d in os.listdir(RESULTS) if os.path.isdir(os.path.join(RESULTS, d))):
        print(f"\n== {cond}")
        print(f'{"setup":22}{"errors":>8}{"native":>8}{"accent":>8}{"short":>7}{"long":>7}{"your words":>12}{"punct±":>8}   recognizer ms (median) short/med/long/50s')
        for f in sorted(os.listdir(os.path.join(RESULTS, cond))):
            if not f.endswith(".json"): continue
            w, t, p, ms = score(json.load(open(os.path.join(RESULTS, cond, f))))
            print(f'{f[:-5]:22}{w["all"]:7.1f}%{w["native"]:7.1f}%{w["accented"]:7.1f}%{w["short"]:6.1f}%{w["long"]:6.1f}%{t[0]:>7}/{t[1]:<4}{p:>8.2f}   {ms["short"]}/{ms["medium"]}/{ms["long"]}/{ms["xl"]}')

if __name__ == "__main__":
    if "--report" in sys.argv: report(); sys.exit()
    cond = sys.argv[sys.argv.index("--cond") + 1] if "--cond" in sys.argv else "room"
    app = sys.argv[sys.argv.index("--app") + 1] if "--app" in sys.argv else os.path.join(ROOT, "build/MurmurEval.app")
    for name in [a for a in sys.argv[1:] if a in CONFIGS]: run(name, cond, app)
