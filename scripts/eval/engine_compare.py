#!/usr/bin/env python3
"""Same audio through each recognition engine, scored on the FORMATTED output (what lands in the app).

Synthesized speech (macOS `say`): a clean US voice plus three accented voices (Milena, Anna, Rishi) reading plain
sentences and sentences full of names / Dictionary words, with pauses and a held key after speaking. Scores: word
error rate per group, Dictionary words spelled right, comma differences, stray "Thank you.", and time (the CLI's asr
stage, which includes loading the model). First run 2026-09-28 — see memory project_murmur_stt_architecture_audit.

    python3 scripts/eval/engine_compare.py WORKDIR [--analyze-only]

WORKDIR holds the generated WAVs and results.json. Uses build/Murmur.app (never the bare binary: it reads a
different settings domain). Runs headless — no windows, no keys, no clipboard. ~10 minutes.
"""
import subprocess, json, os, re, sys, time, collections
WORK = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit(__doc__)
os.makedirs(WORK, exist_ok=True); os.chdir(WORK)
RESULTS = os.path.join(WORK, "results.json")
BIN_DEFAULT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../build/Murmur.app/Contents/MacOS/Murmur")

# id: (what the voice says — [[slnc N]] = a pause of N ms, as when hesitating or holding the key — , reference text)
P = "[[slnc 650]]"
CASES = {
 "pause1": (f"And {P} open the {P} website as you have opened Fluid Voice, and the website view is gone.",
            "And open the website as you have opened Fluid Voice, and the website view is gone."),
 "pause2": (f"Well {P} if the user clicks Get Murmur {P} it should bring them straight to the pricing section.",
            "Well, if the user clicks Get Murmur, it should bring them straight to the pricing section."),
 "pause3": (f"In the hero section {P} where there is a play button to watch the film {P} that should not be there at all.",
            "In the hero section, where there is a play button to watch the film, that should not be there at all."),
 "pause4": (f"We can use the narrator voices {P} there were two voices {P} and I have a Deepgram account we can use.",
            "We can use the narrator voices. There were two voices, and I have a Deepgram account we can use."),
 "terms1": ("I tested Whisper Flow and Murmur today, and Murmur was faster on Planrify.",
            "I tested Wispr Flow and Murmur today, and Murmur was faster on Planrify."),
 "terms2": ("Please check Versel, Revenue Cat and Data for S E O before we launch Murmur on Monday.",
            "Please check Vercel, RevenueCat and DataForSEO before we launch Murmur on Monday."),
 "terms3": (f"We use the Man rope font in the Murmur app {P} the same one as on the website.",
            "We use the Manrope font in the Murmur app, the same one as on the website."),
 "terms4": ("When it runs on whisper dot C P P, the Murmur app should still get every word right.",
            "When it runs on whisper.cpp, the Murmur app should still get every word right."),
}
LONG = ("I want to go through the whole website one more time before we launch it next week. "
        "The hero section should be calm and clear, with one button that says try it for free, and nothing else competing for attention. "
        "Below that, the film should play only when someone asks for it, and the pricing should be simple enough to read in a few seconds. "
        "Everything has to flow cohesively from the top of the page to the bottom. It should feel like one place that was designed on purpose, not a collection of separate pages.")
LONGER = LONG + (" After that I want to check the download page, the license emails, and the manage page, because those are the places "
        "where a new customer decides whether they trust us. If any of them feel rushed or unfinished, we should fix them first. "
        "The same goes for the settings in the app itself.")
CASES["long31"] = (LONG + " [[slnc 2800]]", LONG)
CASES["long50"] = (LONGER + " [[slnc 3000]]", LONGER)
CASES["saidthanks"] = (LONG + " Thank you. [[slnc 2500]]", LONG + " Thank you.")


if '--analyze-only' not in sys.argv:
    # Same audio through each engine; accuracy on the FORMATTED output (what lands in the app), plus time.
    BIN = os.path.abspath(BIN_DEFAULT)
    PLAIN = {
     "plain1": "Can you send me the updated invoice by Thursday afternoon? I need to forward it to the accountant before the end of the month.",
     "plain2": "I'll be a few minutes late to the meeting, so please start without me and I'll catch up on the notes afterwards.",
     "plain3": "The weather was lovely this weekend, so we took the kids to the beach and had fish and chips on the way home.",
    }
    ACCENT_IDS = ["terms1", "terms2", "terms3", "terms4", "pause4"]
    refs = {cid: ref for cid, (_, ref) in CASES.items()}
    def make(cid, voice, spoken):
        path = f"{cid}.wav" if voice == "Samantha" else f"{voice}_{cid}.wav"
        if not os.path.exists(path):
            subprocess.run(["say", "-v", voice, "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, spoken], check=True)
        return path
    clips = {}
    for cid in CASES: clips[cid] = (make(cid, "Samantha", CASES[cid][0]), refs[cid])
    for cid, text in PLAIN.items(): clips[cid] = (make(cid, "Samantha", text), text)
    for voice in ["Milena", "Anna", "Rishi"]:
        for cid in ACCENT_IDS + list(PLAIN):
            spoken, ref = (CASES[cid] if cid in CASES else (PLAIN[cid], PLAIN[cid]))
            clips[f"{voice}_{cid}"] = (make(cid, voice, spoken), ref)
    RUNS = [  # (label, bundle id, engine args)
     ("claude|whisper.cpp", "com.anthropic.claudefordesktop", ["--engine", "whispercpp", "--whisper-model", "large-v3-turbo"]),
     ("claude|parakeet", "com.anthropic.claudefordesktop", ["--engine", "parakeet", "--whisper-model", "v3"]),
     ("mail|whisper.cpp", "com.apple.mail", ["--engine", "whispercpp", "--whisper-model", "large-v3-turbo"]),
     ("mail|parakeet-v2", "com.apple.mail", ["--engine", "parakeet", "--whisper-model", "v2"]),
     ("mail|parakeet-v3", "com.apple.mail", ["--engine", "parakeet", "--whisper-model", "v3"]),
     ("mail|apple", "com.apple.mail", ["--engine", "apple"]),
    ]
    out = {}
    for label, bundle, args in RUNS:
        for cid, (path, ref) in clips.items():
            t = time.time()
            p = subprocess.run([BIN, "--transcribe", path, *args, "--bundle-id", bundle], capture_output=True, text=True, timeout=600)
            wall = time.time() - t
            get = lambda pre, s: next((l[len(pre):] for l in s.splitlines() if l.startswith(pre)), "")
            timing = get("TIMING ms ", p.stderr)
            dec = re.search(r"whisper\.cpp decode: (\d+) ms", p.stderr)
            out[f"{label}|{cid}"] = {"raw": get("RAW: ", p.stdout), "fmt": get("FORMATTED: ", p.stdout), "ref": ref,
                                     "timing": timing, "decode": int(dec.group(1)) if dec else None, "wall": round(wall, 2), "rc": p.returncode,
                                     "err": p.stderr[-300:] if p.returncode else ""}
            print(label, cid, p.returncode, round(wall, 1), get("FORMATTED: ", p.stdout)[:80], flush=True)
        json.dump(out, open(RESULTS, "w"), indent=1, ensure_ascii=False)


d = json.load(open(RESULTS))
TERMS = ["Wispr Flow", "Murmur", "Planrify", "Vercel", "RevenueCat", "DataForSEO", "Manrope", "whisper.cpp", "Deepgram"]
def norm(s):
    s = s.lower().replace("-", " ").replace("/", " ")
    s = re.sub(r"[^\w\s']", "", s)
    return s.split()
def edits(a, b):
    dp = list(range(len(b)+1))
    for i in range(1, len(a)+1):
        prev, dp[0] = dp[0], i
        for j in range(1, len(b)+1):
            cur = min(dp[j]+1, dp[j-1]+1, prev + (a[i-1] != b[j-1]))
            prev, dp[j] = dp[j], cur
    return dp[len(b)]
def group(cid):
    if "_" in cid: return "accented"
    return "plain" if cid.startswith("plain") else "clean"
agg = collections.defaultdict(lambda: collections.Counter())
for key, r in d.items():
    label = key.rsplit("|", 1)[0]; cid = key.rsplit("|", 1)[1]
    ref, hyp = norm(r["ref"]), norm(r["fmt"])
    g = group(cid)
    for bucket in (g, "all"):
        a = agg[(label, bucket)]
        a["err"] += edits(ref, hyp); a["words"] += len(ref); a["clips"] += 1; a["exact"] += (ref == hyp)
    a = agg[(label, "all")]
    for t in TERMS:
        if t in r["ref"]:
            a["terms"] += 1; a["termhit"] += (t in r["fmt"])
    a["commas"] += abs(r["fmt"].count(",") - r["ref"].count(","))
    a["thanks"] += ("thank you" in r["fmt"].lower() and "thank you" not in r["ref"].lower())
    a["rc"] += (r["rc"] != 0)
    m = re.search(r"asr=(\d+)", r["timing"] or "")
    if m and cid in ("terms1", "long50"): a[f"asr_{cid}"] = int(m.group(1))
    if r.get("decode") and cid in ("terms1", "long50"): a[f"dec_{cid}"] = r["decode"]
labels = sorted({k[0] for k in agg})
print(f'{"run":20} {"WER all":>8} {"clean":>7} {"accent":>7} {"plain":>7} {"exact":>6} {"terms":>7} {"comma±":>6} {"thanks":>6} {"asr 5s/51s (ms, incl load)":>28} {"decode":>12}')
for l in labels:
    A = agg[(l, "all")]
    w = lambda b: f'{100*agg[(l,b)]["err"]/max(1,agg[(l,b)]["words"]):.1f}%'
    print(f'{l:20} {w("all"):>8} {w("clean"):>7} {w("accented"):>7} {w("plain"):>7} {A["exact"]:>3}/{A["clips"]:<3}{A["termhit"]:>3}/{A["terms"]:<3} {A["commas"]:>6} {A["thanks"]:>6} {A.get("asr_terms1","-"):>12}/{A.get("asr_long50","-"):<12} {A.get("dec_terms1","-")}/{A.get("dec_long50","-")}  fails={A["rc"]}')
