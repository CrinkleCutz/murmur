#!/usr/bin/env python3
"""Does a candidate build behave exactly like the build you already trust?

Runs the SAME inputs through two Murmur binaries — a frozen baseline and a candidate — using the real CLI chain a
dictation goes through, and reports every input whose output differs:

    --format      formatter → learned corrections → self-correction resolver → snippets
    --harper-fix  the grammar pass
    --edit        the on-device cleanup model + word-preservation guard, run on the FORMATTED text — what the model sees in a
                  live dictation (slower; --model-sample controls how many)

Inputs: the self-correction corpus (scripts/eval/self_correction_corpus.py), a fixed set of tricky sentences, and — if
present — the user's own dictation history (read at run time from Application Support, never copied anywhere).

Speed-only changes must show ZERO differences. A change that is meant to alter behaviour must show only the
differences it intends: read the listed diffs.

    scripts/eval/regression_check.py --baseline build/Murmur_baseline.app --candidate <path/to/Murmur.app>
"""
import argparse, json, os, random, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from self_correction_corpus import build_corpus  # noqa: E402

HISTORY = os.path.expanduser("~/Library/Application Support/Murmur/history.json")
TRICKY = [
    "I need a apple and an banana.", "The results was better than expected.", "Please send it to John and I before Friday.",
    "There is to many open issues right now.", "We might loose the data if the disk fails.", "Both teams finished there part of the work.",
    "So, um, what the future means, you know, is a big question for all of us.", "The card is, like, way too big compared to the other ones on the page.",
    "I could of finished the report if their was more time yesterday.", "What the future means.", "The future of work.", "Is this correct?",
    "We deploy on Versal and my name is Giannis.", "Please review the formounted output before 1030.", "I asked Fable to check the Vercel deploy and Planrify for Jānis today.",
    "I need to use async await in the view model and check the useState hook.", "Send me the env file and the config before the double check.",
    "The colour and the organisation of the page look better.", "It uses 8 GB of RAM and takes 200 ms per request.", "Let's meet Friday, actually Monday too.",
    # Start-over commands ("scratch that"…): the designed wipe must not change unless the correction is a bare in-place swap.
    "Let's meet Tuesday. Scratch that, Wednesday works better.", "First idea. Scratch that. Second idea. Scratch that. Third idea.",
    "Send the invoice on Friday, scratch that, Monday works for the team.", "The meeting is Friday. Forget that. Let's do Monday instead.",
    "I think we should ship it. Never mind that. We need more tests first.", "Testing testing, forget that. Let's start over with the real message.",
    "Buy milk, scratch that, eggs.", "We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.",
    "We can do the meeting on the Friday 5pm, no, actually do that Tuesday 5pm.", "I'll send the report on the 5th, sorry, I'll send it on the 7th.",
    "Sorry for the delay, I was in a meeting.", "I mean it, this is really important.", "I have 3 kids, actually 2 boys and 1 girl.",
    # A day inside "Friday at 3pm" and its neighbours: the day swaps, the time stays; the look-alikes stay as dictated.
    "Let's meet Friday at 3pm, no wait, do it on Monday.", "Let's meet Friday at 3pm, scratch that, do it on Monday.",
    "We can do the meeting on Friday at 3pm, no wait, do that on Monday at 4pm.", "Let's meet Friday at 3pm, no wait, do you want Monday?",
    "Let's meet Friday at 3pm, no wait, do it on Monday and Tuesday.", "Let's meet Friday at 3pm, actually do it on Monday.",
    "Let's meet at 3pm, no wait, do it Monday at 4pm.", "Let's meet Friday the 5th, no wait, do it on the 6th.",
    # Periods that belong to a word or abbreviation must not start a sentence ("3 p.m. on Friday", "e.g. a hammer").
    "Let's meet at 3 p.m. on Friday.", "The shift is 9 a.m. to 5 p.m. tomorrow.", "We meet at 3 p.m. We'll bring lunch.",
    "Use a tool, e.g. a hammer, for that.", "Visit example.com today and read version 3.5 notes.", "Dr. Smith said the U.S. team lands at 9 a.m. on Monday.",
    "hello world. this is fine. it works. really", "It costs 5 dollars etc. and more.",
    # Times: one house style ("3pm", "3:30pm"), numbers-that-are-times become times, non-times stay.
    "Let's meet at 3 PM tomorrow.", "The call is at 3:30 p.m. today.", "It ends at 3.30pm.", "Call me at 330 pm.",
    "Standup is at 1030 AM.", "We looked at 930 Main Street and it costs 930 dollars.", "The PM said we hired 2 PMs.",
    "Meet at 3 p.m. Friday.", "I'm free from 9 a.m. until 5 p.m., so pick a time.",
]


def binary(app):
    path = app if app.endswith("Murmur") else os.path.join(app, "Contents", "MacOS", "Murmur")
    if not os.path.exists(path):
        sys.exit(f"no binary at {path}")
    return path


def run(bin_path, args, extra=()):
    p = subprocess.run([bin_path, *extra, *args], capture_output=True, text=True, timeout=400)
    return p.stdout.strip()


def deterministic(bin_path, text, bundle):
    formatted = run(bin_path, ["--format", text], ["--bundle-id", bundle])
    return formatted, run(bin_path, ["--harper-fix", formatted], ["--bundle-id", bundle])


def compare(name, texts, fn, workers, limit=12):
    with ThreadPoolExecutor(workers) as ex:
        base = list(ex.map(lambda t: fn(BASE, t), texts))
        cand = list(ex.map(lambda t: fn(CAND, t), texts))
    diffs = [(t, b, c) for t, b, c in zip(texts, base, cand) if b != c]
    print(f"{name}: {len(texts)} inputs, {len(texts) - len(diffs)} identical, {len(diffs)} differ")
    for t, b, c in diffs[:limit]:
        print(f"    IN  : {t[:140]}\n    BASE: {b if isinstance(b, str) else b[-1]}\n    CAND: {c if isinstance(c, str) else c[-1]}")
    return len(diffs)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True); ap.add_argument("--candidate", required=True)
    ap.add_argument("--history", type=int, default=250, help="how many of the user's real dictations to include")
    ap.add_argument("--model-sample", type=int, default=60, help="how many inputs also go through the cleanup model")
    ap.add_argument("--bundle", default="com.openai.codex")
    ap.add_argument("--candidate-edit-args", default="", help="extra flags for the candidate's --edit (e.g. --prewarm)")
    ap.add_argument("--max-diffs", type=int, default=12, help="how many differing inputs to print per section")
    ap.add_argument("--only-model", action="store_true", help="skip the deterministic section (already reviewed)")
    a = ap.parse_args()
    BASE, CAND = binary(a.baseline), binary(a.candidate)
    corpus = [r["input"] for r in build_corpus()]
    real = []
    if os.path.exists(HISTORY):
        real = [e["text"] for e in json.load(open(HISTORY))][: a.history]
    texts = list(dict.fromkeys(corpus + TRICKY + real))
    total = 0 if a.only_model else compare("format + grammar", texts, lambda b, t: deterministic(b, t, a.bundle), 4, a.max_diffs)
    random.seed(7)
    sample = random.sample(texts, min(a.model_sample, len(texts)))
    sample = list(dict.fromkeys(TRICKY + sample))
    extra = a.candidate_edit_args.split()
    bundle_args = ["--bundle-id", a.bundle]
    # Each binary formats the dictation with ITS OWN formatter/resolver first, exactly like a live dictation, and its
    # cleanup model sees that text — feeding raw text would exercise a path the app never takes.
    total += compare("cleanup model + guard (on formatted text)", sample,
                     lambda b, t: run(b, ["--edit", run(b, ["--format", t], bundle_args) or t],
                                      bundle_args + (extra if b == CAND else [])), 3, a.max_diffs)
    print("\nRESULT:", "IDENTICAL" if total == 0 else f"{total} difference(s) — review the diffs above")
    sys.exit(0 if total == 0 else 1)
