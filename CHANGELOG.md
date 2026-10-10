# Changelog

## Unreleased

### New

- **Translate into: speak one language, paste another.** Pick a language in Settings ▸ Dictation ▸ Translate into
  (or from the language menu on the bar, the menu bar icon, or the first-run language step) and Murmur pastes what
  you say in that language — translated on this Mac, after your words are recognised and cleaned up in the language
  you speak. Settings shows a real before-and-after from the translator you have, and the bar's language button
  reads "→EN" while it's on.
  - **Which translator:** the one built into macOS, with nothing to download; **Gemma 4** (5 GB, optional), the most
    natural in our test of 16 translators across 13 languages; and **EuroLLM** (5 GB, optional) for Latvian, the one
    model that gets Latvian right both ways. Murmur picks for you.
  - **Checked before it's pasted:** every name, number, time, date, link, email and snippet has to come through, and
    the text has to be in the language you asked for — "Thursday" turned "Wednesday" or "€1,240" turned "1.420 €"
    pastes your own words instead, and the notch says why ("Pasted as you said it — a date didn't match").
  - Never in a terminal or code editor. An app can have its own choice in App Profiles (or none).

- **Work with your coding agents out loud.** Murmur now reads what kind of field you're dictating into — not just
  which app — and writes for it:
  - **A prompt box** (Claude Code or Codex, including when they run inside Terminal; Claude's Code tab; the Codex app;
    Cursor's, Copilot's or Xcode's chat) gets a clean paragraph, with your project's names spelled the way the repo
    spells them: "um add a retry to the text inserter and uh run the tests" → "Add a retry to TextInserter and run the
    tests."
  - **A shell** gets your exact words, written as a command: "git rebase dash i head tilde three" → `git rebase -i
    HEAD~3`, "npm run test dash dash watch" → `npm run test --watch`, "ls sources slash murmur slash star dot swift" →
    `ls Sources/Murmur/*.swift`. With whisper.cpp, a shell's recognition is given commands as its example, so it
    writes them itself.
  - **A code editor** gets your exact words with spoken code as code: "open paren", "dot", "equals", "camel case
    upload client retry" → `uploadClientRetry`, "snake case", "kebab case".
  - **Names from your project:** the project is the one the app is working in (the window's document, a path in its
    title, or the folder its own agent or shell is in), and its file names — never their contents — are used to
    spell what you say: "open the snippet editor sheet" → `open SnippetEditorSheet.swift`, even when it's misheard
    ("voice snicket store" → `VoiceSnippetStore`).
  Say "literally" before a word to keep it a word. A style you set for an app in App Profiles still wins.

- **Edit selected text by voice.** Select text in any app, hold the dictation key and say what to change — "make
  this shorter", "fix the grammar", "turn this into bullet points", "as a numbered list", "translate it into Spanish",
  "make it more formal", "rewrite it as an email to Anna" — and the selection is rewritten in place (⌘Z puts it back).
  Nothing to set up: anything else you say over a selection is dictated as usual. Each kind of edit uses what Murmur
  does best for it (grammar fixes run on Polish; lists and shortening have their own examples; an email keeps your
  words between "Hi Anna," and your sign-off), and the result is checked: if it would change or invent a name,
  number, time or date, or answer your text instead of editing it, your selection is left exactly as it was. The
  selection is read through Accessibility — your clipboard isn't touched to find it. English dictation.
- **The clean-up now works in German, French, Spanish, Italian, Dutch, Portuguese and Swedish.** "Äh", "euh", "hã"
  and other hesitation sounds are removed, words said twice are dropped, and punctuation, capitals, articles and word
  endings are fixed ("mit den Kunde" → "mit dem Kunden") — always in your language, never translated. It's held to
  stricter rules than English: any other word the model changes, adds or drops is put back. Measured on 21 sentences:
  the unchecked model changed the meaning of 4 ("Also ich glaube" → "Auch ich glaube"); with the check, none.
  Templates and styles stay English (and Latvian for templates).

- **Snippets keep your text exactly as you wrote it.** Before, your saved text went in before the clean-up, and the
  clean-up then edited it like any other words: it could delete a saved signature or instruction (and then throw away
  the whole clean-up), flatten an address onto one line, or add commas around a link. Now Murmur sets your text aside
  while it cleans up your own words, applies templates, grammar and per-app formatting, then puts it back word for
  word. A sign-off at the end gets its own paragraph, without a stray full stop, and saying just the phrase pastes
  just the text. Phrases match whatever the capitals, commas or hyphens ("My calendar-link," still works), in any
  language.
- **Snippets can fill in today's date, the time or what you copied** at the moment they're pasted: use the Insert
  buttons, or type {today's date}, {time} or {what I copied}.
- **New snippet window.** "When I say…" / "…paste this", with a live preview of what you'd say and what gets pasted,
  a warning when the phrase is an everyday word you'd say by accident, and a note when another snippet or template
  already uses it. It replaces the small inline row. New starters: my calendar link, my address, my sign-off and
  today's date.

- **New template, made simple.** One sentence to fill in: "When I start with ___, turn what I say into ___." Starter
  buttons write the description for you (Bullet points, An email, A checklist, Notes with headings, A short message, A
  LinkedIn post, Translate to…), and **Try it** shows the real result before you save — say or type a sample. If your
  description names parts ("what I did yesterday, what I'm doing today, and anything blocking me"), Murmur makes them
  headings by itself. Under More options: the name, apps it's always used in (no phrase needed there), and an optional
  "You say → You want" example. The sheet tells you when something's missing — no phrase or app, a phrase another
  template already uses, or saying phrases switched off (with a Turn on link). Your own templates can now be edited.
- **Templates work in Latvian.** Say "sapulces piezīmes", "kopsavilkums", "e-pasta melnraksts", "uzdevumu saraksts" or
  "bloga ieraksts" (or your own phrase). Apple's on-device model doesn't support Latvian well enough to write it, so
  for Latvian Murmur keeps every line in your own words and only arranges them — headings ("Galvenais", "Lēmumi",
  "Darāmais"), "Labdien!" and "Ar cieņu," are Murmur's own. Clean-up and styles stay English-only.
- **Large v3 for whisper.cpp — best for accents.** A new choice in Settings ▸ Recognition ▸ Model, next to Large v3
  Turbo (now "precise and fast"): the full model, measured on 150 realistic English recordings at 4.6% errors for
  accented voices (Turbo 5.8%) and 5.3% for short dictations (Turbo 8.6%), but slower (0.64 s instead of 0.39 s for a
  short dictation) and a little worse on long ones. ~3.1 GB, downloaded when chosen. The Latvian model is unchanged.
- **Murmur knows where your text is going — even inside a browser or Claude.** While you talk it reads the window
  you're dictating into (Accessibility, no new permission, nothing kept): the page's address, or the browser's address
  bar. So Gmail or Outlook on the web gets email formatting, Slack, WhatsApp or Discord on the web gets chat
  formatting, and Claude's Code tab, Codex, claude.ai/code, chatgpt.com/codex, terminals and editors count as a coding
  agent. **Prompt Engineer** uses it: in Claude Code or Codex your prompt keeps every file, screen and error message
  exactly and says under "Done when" how the agent can tell a problem is fixed; in a chat it stays a plain request.
- **Names on your screen come out right**: while you talk, Murmur reads the names in the window you're dictating
  into — through Accessibility, which it already has (no screenshot, no new permission) — and uses them for that one
  dictation: a word the recognizer wasn't sure of that clearly is one of those names is written that way ("Superbase"
  → Supabase, "DeepRAM" → Deepgram). Your own words always come first, everyday words are never picked up, and nothing
  is stored or sent anywhere. Measured on 150 realistic recordings with names that were only on screen, not in the
  vocabulary: names right 152 → 167 of 240, 15 better, none worse — also with 215 other names on screen; together
  with your own vocabulary 163 → 167. Reading the window takes 70–320 ms, while you're still talking.
  `defaults write local.murmur screenNames -bool false` turns it off.
- **Murmur learns from your own corrections**: fix a misheard name by hand right after a dictation lands ("Manrog" →
  "Manrope") and it's learned, the same way an edit in History is — so the next dictation gets it right. It works in
  chat boxes too: the box is watched until you move on, and the last settled version before you press Return is what
  counts (a word caught half-typed is never learned). You see "Learned “Manrope”", and it's listed under the bell,
  which opens Voice Profile where it can be removed. Only a word changed into a name or an unusual word counts;
  rewording, added words and grammar are ignored, and nothing is kept but the corrected pair.
  `defaults write local.murmur learnFromEdits -bool false` turns it off.
- **Text fits where your cursor is**: continuing right after a word gets the missing space, and continuing a sentence
  starts with a lower-case ordinary word ("…and then" + "The rest" → "…and then the rest"); names, "I" and acronyms
  keep their capitals. Nothing changes where the text before the cursor can't be read, in passwords or in Raw style.
- **Punctuation, layout and addresses said out loud**: "comma", "question mark", "full stop", "period", "exclamation
  mark", "colon" and "semicolon" become the mark, whatever punctuation the recognizer put around the word — but not the
  noun ("add a comma", "a trial period"). "bullet point" starts a "- " line; "quote … unquote" (or "end quote") becomes
  "…"; "open parenthesis … close parenthesis" becomes (…); "state hyphen of hyphen the hyphen art" becomes
  state-of-the-art; "dot dot dot" becomes …; "hashtag launch" becomes #launch; "ampersand" becomes &; "20 percent"
  becomes 20%. A spelled-out address becomes one — "jane at example dot com", or "email jane at example.com" as the
  recognizer half-writes it, becomes jane@example.com; "murmurmac dot com" becomes murmurmac.com — while "look at
  google.com" and "we're at booking.com" stay sentences. Checked end to end with spoken recordings on whisper.cpp and
  Parakeet, and against 500 real dictations. English only.
- Web addresses and emails are no longer changed by your taught words or the name fix ("murmurmac.com" had become
  "Murmur mac.com").
- **The recording HUD grows out of the notch** on MacBooks that have one: the notch expands into the same rounded pill
  the bottom of the screen shows, in the notch's own black — the target app's icon on the left, the waveform (or
  dots while working) on the right, the status label under the notch. It pops out when you start and shrinks back
  into the notch when the text lands (a plain fade with Reduce Motion). Screens without a notch — an external
  display, a Mac that has none — keep the pill at the bottom exactly as before, and so does the nav bar. Nothing
  to set up; it never takes focus, so text still lands where your cursor is.

- **Auto (match app)** style (opt-in, under Style): shapes a finished dictation for the app it is going into
  without changing a word. In email apps (Mail, Outlook, Spark, Mimestream, Airmail, MailMate, Thunderbird) a
  spoken greeting and sign-off get their own lines; in messengers (Messages, Slack, WhatsApp, Telegram, Signal,
  Discord) a short single-sentence message loses its final full stop. Every other app stays exactly as spoken.
  Deterministic, English only, never in Raw style.

- **Notetaker**: on-device meeting notes. Detects an in-progress meeting via
  your calendar or (optionally) your browser's active tab, captures mic +
  system audio, transcribes and corrects it through the same Harper/
  dictionary pipeline as regular dictation, and generates a title, summary,
  decisions, and action items. Notes can be renamed, have action items
  checked off, and copied as one formatted block. Hide-from-screen-capture,
  auto-stop when the call ends, a configurable max recording length, and
  its own rebindable hotkey (⌥M by default).
- **Custom Transforms**: create your own ⌥-triggered rewrite shortcuts
  alongside the built-in Polish (⌥1) and Prompt Engineer (⌥2) — up to seven
  more, auto-assigned ⌥3–⌥9. A new card grid replaces the old plain list,
  with "Reset to defaults" and an ⌥⇧Z to undo the last transform via the
  target app's own ⌘Z.
- **Cleanup levels** on the Style page (Light / Concise) — a second axis
  alongside tone, for trimming wordiness independent of how formal the
  rewrite sounds.
- Snippets now track a per-snippet usage count, and the page leads with a
  "try something like" example card teaching what a snippet can do,
  including using one as a saved rewrite prompt.

### Fixed

- The Templates page's "Try it" box gave the old, weaker results — it now runs exactly what a dictation gets.
- The name fix no longer turns an ordinary contraction into a name ("you've" became "Vue", a developer term): words
  with an apostrophe count as ordinary English, and sounding alike now takes more than one shared consonant.
- **Dictating into Murmur's own fields works** — Voice Profile, Dictionary, Style, App Profiles, Snippets, Templates,
  Scratchpad, Ask: the text goes straight in at the cursor, as if typed (with the usual space after a word, and ⌘Z to
  undo it), without touching the clipboard. It used to reach History only: Murmur has no menu bar, so the ⌘V it sent to
  itself had no Paste to trigger. For the same reason ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z now work when typing in Murmur's fields.

### Changed

- **The template window is spaced like Apple's own sheets.** One spacing scale throughout, labels lined up with their
  fields, both example boxes the same size, Try it in a bar under its box instead of floating at the far right, a
  real Cancel button next to Save, and a status line that never wraps. Both windows fit inside the app window, scrolling
  if it's small.
- **Templates rebuilt — each one now does its job.** Say "meeting notes", "summarize this", "email draft", "task
  list" or "blog post" at the start of a dictation (or set a template for an app). Before, most handed the dictation
  back unchanged, Email Draft wrote "[Your Name]" placeholders, and Task List made up tasks. Now:
  - **Meeting Notes**: attendees, key points, decisions, action items with who and when, open questions.
  - **Summary**: two or three main points in one short paragraph, numbers and dates kept exactly.
  - **Email Draft**: a subject, a greeting to the person you named ("Hi Sophie," / "Hi team,"), a body written to
    them ("Could you ask legal…?"), and your first name from your Mac as the sign-off.
  - **Task List**: every task as a checkbox, with who and when if you said so.
  - **Blog Post**: a title, an opening and sections, without repeating itself.
  A template that would invent a name, number or date — or a summary no shorter than what you said, or a task list of
  something with nothing to do — isn't applied: your words go in as spoken, and Murmur says why.
- **Transforms rebuilt — Polish and Prompt Engineer do their jobs now.** They used to run under dictation clean-up's
  "lightly edit, stay short" rules, so Polish mostly moved commas and Prompt Engineer squeezed every request into one
  line that ended in its own instruction ("Constraints/Format: Structured prompt for AI assistant."), dropped details
  and invented requirements. Now each transform has its own rules with worked examples:
  - **Polish** fixes the grammar ("needs fixed" → "needs to be fixed"), splits run-on sentences, removes stumbles and
    repeated words, writes macOS and 3pm, and keeps your meaning, voice, contractions, questions and "I think". About
    1.9 s instead of 3.1 s.
  - **Prompt Engineer** writes a prompt the way Anthropic, OpenAI and Google recommend in 2026: the goal first, the
    context in your voice with every detail kept, each request on its own line, only the constraints you stated, and
    "Done when" / "Open questions" only when you said something of the kind. A short request stays one line.
  - **Your own transforms** follow your instructions properly ("Translate into German", "Make it a bulleted list").
  - A safety check refuses any rewrite that changes or invents a name, number, link, email or file name, leaves out
    part of your text, answers it instead of rewriting it, or turns your question into a statement — your text then
    stays exactly as it was, and Murmur says why. Pasting uses the same reliable paste as dictation.
- Voice Training listens with the engine you dictate with (it used Apple's engine whatever you'd chosen, so it taught
  Apple's mishearings), with the word you're teaching already in your vocabulary — so what it learns is exactly what
  dictation would get wrong.
- Everyday words swapped for everyday words ("For action" → "Correction") are no longer learned from History edits or
  Voice Training: as an automatic swap they'd rewrite normal speech ("ready for action").
- **Per-app formatting is on by default** (Style "Auto (match app)"): email gets a spoken greeting and sign-off on their
  own lines, a short chat message loses its final full stop, and every other app gets the text exactly as spoken. An
  app with its own style in App Profiles keeps it.
- Setup gives English speakers Parakeet v2 rather than v3: on accented English it makes about half the errors
  (6.1% vs 11.4% on the same recordings); v3 stays the choice for the other languages it covers.
- **Long dictations land sooner with whisper.cpp**: a dictation that runs past about 16 seconds is cut at a natural
  pause and the part already spoken is transcribed while you keep talking, so letting go of the key leaves only the
  last stretch to do. Measured on 45–50 second dictations: the wait after release went from 1.16 s to 0.57 s on an M2
  Max (more on a Mac with a smaller graphics chip), with the same accuracy — and a sentence whisper.cpp used to invent
  at the end of dictations over 30 seconds is gone. Shorter dictations are decoded exactly as before, and any problem
  falls back to decoding the whole recording. `defaults write local.murmur liveChunking -bool false` turns it off.
- Licensing for the official paid builds sold from murmurmac.com: a 7-day free trial, license keys that work on
  2 Macs (Team keys on more), a weekly check-in with two weeks' grace offline, and updates through Sparkle — signed,
  and limited to what the license covers (a year for the one-time plan, forever for Lifetime). An official build
  has a License tile in Settings (trial, "Already have a key?", plan, updates included, Macs, Deactivate this Mac)
  and a `murmurmac://activate?key=…` link for the receipt email; without an active license, dictation, Notetaker,
  Transforms and Ask Murmur pause, with the reason in the HUD and in Settings. None of it is active in a build from
  source, which works and updates exactly as before — free, no license needed. The contract the website implements
  is in `docs/licensing-api.md`; `scripts/make_release.sh` makes an official build.
- Settings: the line under the title matches the tiles again (it still mentioned the removed theme picker), General
  says when a build is from source, and every tile is built from one shared set of rows, labels and buttons.
- A build from source can show a **License preview** (Settings → General → Show preview): the real License tile on a
  pretend server and clock, with controls to skip a week, go offline, refund, flag a newer version and show the paused
  HUD — so the paid experience can be seen and tried without a licence server. It lives only in memory and never
  pauses the build's own dictation.
- The recording pill at the bottom of the screen and the nav bar (with its popovers) are now true black, the exact
  colour of the MacBook notch, so the whole HUD family matches it.
- Settings is now organized into collapsible accordion tiles (General,
  Dictation, Notetaker, Privacy & Permissions), matching the Help page's
  layout instead of one long scrolling list. The version/update status
  only shows its orange highlight when an update is actually available.
- The floating HUD dropped its live-transcript preview text — a different,
  lower-quality model than whichever engine you've actually selected,
  often late or wrong before the real transcript replaced it — down to a
  simpler icon + waveform + status-label footer.
- Settings' General card no longer has a Light/Dark/System picker — dark
  mode isn't reliable enough to ship yet, so appearance is pinned to light
  for now.

### Fixed

- Pasting into a remote desktop or virtual machine (Microsoft Remote Desktop, Citrix, Horizon, Parallels, Jump
  Desktop, UTM…), where ⌘V isn't paste, now copies the text and says "Copied — paste inside the session".
- An app that ignores a synthetic ⌘V now gets its own Paste menu item pressed once, when nothing read the text within
  two seconds — found by its ⌘V shortcut, so it works in any language, and never pasting twice.
- **Names come out right more often, on every engine that can tell**: when the recognizer wasn't sure of a word and
  it's close — in spelling or in sound — to one of your own words or names, Murmur writes your word ("Manrog" →
  Manrope, "Parricate" → Parakeet, "Vershall" → Vercel, "Mirma" → Murmur). A word the recognizer was sure of, or an
  ordinary English word, is never changed. Measured on 150 realistic recordings with accented voices, names right out
  of 240: whisper.cpp 179 → 183, Parakeet 152 → 163, Parakeet in developer apps 161 → 171, WhisperKit 131 → 148, Apple
  84 → 87 — every changed dictation better or unchanged, none worse. Nemotron and the sherpa-onnx models don't report
  how sure they are of each word, so they can't use it. English only.
- whisper.cpp hears the first word of a dictation better: it now gets a moment of silence before your speech
  (first-word errors down about a fifth on the same recordings).
- **Microphone choice** is automatic and safe with the lid closed: the Mac's own microphone while the lid is open (it
  starts fastest — measured 155 ms to the first audio against 555 ms for a Studio Display microphone, and whatever is
  said while a microphone is starting is lost), and with the lid closed — where the built-in mic is disconnected in
  hardware and records pure silence — the microphone chosen in System Settings, or the first wired one. Bluetooth
  headsets and virtual devices are still stepped around. Nothing to set.
- A dictation interrupted by the audio hardware changing (a headset connecting, a dock, the Mac waking) used to lose
  the rest silently; it's now transcribed up to that point, with the reason in the error line.
- The end of the last word is no longer cut: Murmur keeps listening for the audio still on its way when the key comes
  up (about a tenth of a second), and whisper.cpp's resampler now hands over its final milliseconds.
- A microphone delivering pure digital silence (access denied, a headset busy with another device, a mic held by
  another app) now says so instead of "Didn't hear anything", and a denied microphone is caught before recording.
- Pasting is safer: if a different app came to the front while Murmur was finishing, the text is copied instead of
  pasted into the wrong place; if the app in front never took the text, the HUD says so (it's in History); a modifier
  key still held from a hotkey can no longer turn ⌘V into another command; and if macOS would ask before Murmur reads
  the clipboard, the save-and-restore step is skipped rather than prompting on every dictation.
- whisper.cpp accuracy: its vocabulary prompt was a 150-term list that whisper.cpp cut from the front, full of
  everyday words the Dictionary had collected, and its comma-list style turned pauses into commas ("and, open the,
  website"). It's now one short sentence — every word you taught first, then Murmur's own names and unusual words — and the WhisperKit engine gets the same sentence: on the same recordings, word
  errors 1.5% → 1.1% and commas at pauses 2 → 0 — and with the Dictionary fixes below, dictionary words 10/13 → 13/13.
- "Murmur." with a full stop mid-sentence after every "Murmur": a Dictionary entry saved with its full stop. Entries
  are now always read and learned without sentence punctuation.
- A stray "Thank you." at the end of dictations of 30 seconds or more — Whisper filling the silent end of its last
  30-second window. A sign-off phrase over silent audio is now dropped; one you actually say stays.
- Learning from History edits no longer pairs unrelated words ("and then through the" → "from Chat"): a learned
  correction's two sides have to be spelled at least somewhat alike. Your own corrections now also match the same
  letters split or joined differently ("Whisper Flow" for "Whisperflow"), and names keep the capitals you gave them.
- The Formal, Casual, Very casual and Concise styles could answer a dictation instead of restyling it:
  "Can we push the launch by a week?" came back as "Sure, let's push the launch by a week." (a question
  turned into a decision), and a "Hey!" or a "thanks!" nobody said was added on the front or the back.
  A rewrite that opens with a reply, a greeting, thanks or an offer/sign-off you didn't say is now refused
  and your dictation stays as you said it (a spoken "thanks" can still become "thank you"). Templates,
  which are meant to add a greeting and a sign-off, are unaffected.

## v2.1.0 — 2026-09-10

Dictation language support now actually works end-to-end — the language
picker, the recognition engines, and every post-processing step agree with
each other, which they didn't before. Also a warm-palette redesign across
most of the app.

### New

- **Fourth recognition engine**: Parakeet, NVIDIA's TDT model running via
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Core ML on
  the Neural Engine) — Murmur's fastest engine yet, in two sizes (English
  v2, multilingual v3). Vocabulary biasing isn't available for it yet,
  unlike the two Whisper engines.
- **Dedicated Latvian model**: a whisper.cpp option running the University
  of Latvia AI Lab's Interspeech 2025 fine-tune of Whisper large-v3 —
  3.2% word error rate on Latvian versus Parakeet v3's 22.84%.
- Settings' language picker now reflects whichever recognition engine and
  model is actually selected, instead of always showing Apple's fixed
  on-device locale list regardless of engine.
- GitHub Releases-based update checking on the Software settings page —
  no auto-installer, "Update Now" opens the release in your browser.

### Fixed

- Harper's grammar pass, personal "learned corrections," your dictionary,
  and the Apple Intelligence cleanup pass all ran unconditionally on every
  dictation regardless of language — for anything other than English, they
  silently "corrected" real words toward English ones. All four now only
  run when the dictation language is English.
- Switching to an English-only model (Parakeet v2, Distil-Whisper) and
  back used to leave you stuck on English afterward instead of restoring
  your actual language.
- Parakeet v3's language list is cut from the 25 NVIDIA documents down to
  the 10 FluidAudio's own benchmark measures under 10% word error rate —
  the rest weren't accurate enough to offer without a real fix (see the
  Latvian model above for the one language that got one).
- Settings dropdown panels (Recognition engine, model pickers, Language)
  could clip against the bottom of the window at its default size, or
  float away from their own trigger instead of opening right above/below
  it — root cause was a SwiftUI environment value silently resolving to
  `nil` one level higher in the view hierarchy than it needed to.
- The Dictation key picker now matches the same dropdown style as every
  other control on the Settings page, instead of an older, plainer one.

### Changed

- Warm-palette redesign across Home, Ask Murmur, Scratchpad, Style,
  Templates, Transforms, Voice Profile, Dictionary, Snippets, Insights,
  Help, Legal, and App Profiles.

## v2.0.1 — 2026-08-25

Fixes for the floating nav-bar HUD (the small pill that appears near the
bottom of the screen while Murmur is idle).

### Fixed

- Its popovers (Templates/Transforms, More, Listen) could render with their
  rounded corners and shadow sheared off flat, or clipped on one side —
  the panel they draw into was a fixed size too small for their actual
  content.
- Moving the cursor from a popover's trigger icon into the popover itself
  could close it before you reached it, since there was a real screen gap
  between the two with no hover coverage.
- At idle, the HUD's hit-region was the full nav-bar footprint (invisible,
  but still solid) — enough to swallow clicks meant for another
  bottom-docked utility sitting in the same part of the screen. Idle state
  now shows a small reveal-pill with a much smaller footprint, which grows
  into the full bar only when you hover it.
- The reveal/collapse between the small pill and the full bar is now a
  smooth, staged grow/shrink instead of an instant swap.

## v2.0.0 — 2026-08-23

The first public update since the original release — a full redesign, built and
open-sourced under MIT.

### New

- **Third recognition engine**: whisper.cpp running via Metal on the GPU,
  alongside Apple's built-in SpeechAnalyzer and WhisperKit. Murmur's fastest
  engine.
- **Harper grammar pass**: a deterministic, local, millisecond-speed grammar
  and style check that runs alongside the Apple Intelligence edit pass —
  catches agreement, punctuation, and repeated words the LLM edit occasionally
  misses. No model, no warm-up, no network.
- **Per-app profiles**: one place to set what Murmur does when you dictate
  into a specific app — tone and note template together, replacing two
  separate override systems that used to answer that question differently.
- **Ask Murmur**: ask questions about your own dictation history, answered
  entirely on-device via keyword retrieval into the local model.
- **Note templates**: restructure a transcript into a specific document shape
  via the on-device LLM; trigger one by voice at the start of a dictation.
- **Guided first run**: welcome → permissions → recognition engine → hotkey
  → mic test, shown once.
- **Hallucination filtering** for Whisper-family engines — phrase-matches the
  small, well-documented set of sign-off hallucinations ("Thank you.", etc.)
  those models produce on near-silent audio.
- **Legal page**: in-app licensing info for Murmur itself and its four
  open-source dependencies (also now in [NOTICE.md](NOTICE.md)).

### Changed

- Full UI redesign — a multi-view dashboard (Home, Insights, Ask Murmur,
  Scratchpad, Dictionary, Voice Profile, Style, Snippets, Templates,
  Transforms, Settings) replacing the original single menu-bar view.
- Murmur is now open-source under MIT. Between this release and the last, it
  was developed as a closed-source commercial product; that plan was dropped
  in favor of open-sourcing the whole thing.

## v1.0.0 — 2026-07-20

Initial public release: push-to-talk dictation via Apple's on-device speech
recognition or WhisperKit, cleanup pipeline, pronunciation learning, Styles,
Transforms, and a dashboard with history and usage stats.
