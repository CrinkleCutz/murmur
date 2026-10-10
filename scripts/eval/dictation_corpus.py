"""Realistic dictation test set: the founder's own past dictations (errors corrected by hand), a few with fillers and a
spoken self-correction, voiced by Deepgram Aura-2 in native AND accented English (German, Dutch, Italian voices reading
English), then passed through a laptop-in-a-room chain (band limit, early reflections, pink noise) with the key held
after speaking. Each item: id -> (what is spoken, what should land in the app)."""

ITEMS = {
 # short
 "s_stripe":   ("Yes, I will be using Stripe for checkout.", "Yes, I will be using Stripe for checkout."),
 "s_leading":  ("You can even look up the leading apps, which are Wispr Flow and superwhisper.",
                "You can even look up the leading apps, which are Wispr Flow and superwhisper."),
 "s_repo":     ("If that's not available in the folder, I can give you the GitHub repo for the app itself.",
                "If that's not available in the folder, I can give you the GitHub repo for the app itself."),
 "s_font":     ("Research a premium font. The secondary font is Newsreader. Is that the best pair for the Manrope font?",
                "Research a premium font. The secondary font is Newsreader. Is that the best pair for the Manrope font?"),
 "s_meeting":  ("We can do the meeting on Tuesday at 5pm.", "We can do the meeting on Tuesday at 5pm."),
 "s_folder":   ("Can you see a folder on my Mac?", "Can you see a folder on my Mac?"),
 "s_correct":  ("Let's meet at 5pm, no, actually, let's meet at 6pm.", "Let's meet at 6pm."),
 "s_dev1":     ("Ask Claude Code to check the Supabase config and push the fix to Vercel.",
                "Ask Claude Code to check the Supabase config and push the fix to Vercel."),
 "s_dev2":     ("Run the tests in Codex, then open a pull request on GitHub.",
                "Run the tests in Codex, then open a pull request on GitHub."),
 # medium
 "m_compare":  ("Compare our website against Wispr Flow. We have to get the design as close to Wispr Flow as we can, so it feels like human design, highly curated.",
                "Compare our website against Wispr Flow. We have to get the design as close to Wispr Flow as we can, so it feels like human design, highly curated."),
 "m_dmg":      ("They shouldn't be able to download this DMG file, they should only be able to get the repo from GitHub. So maybe this DMG file has to be stored somewhere other than GitHub.",
                "They shouldn't be able to download this DMG file, they should only be able to get the repo from GitHub. So maybe this DMG file has to be stored somewhere other than GitHub."),
 "m_notch":    ("I found something in the VoiceInk app: their HUD pill is integrated in the notch and uses that space. That would be way better, because it is at the top and then pops on and off.",
                "I found something in the VoiceInk app: their HUD pill is integrated in the notch and uses that space. That would be way better, because it is at the top and then pops on and off."),
 "m_vercel":   ("We can still work on the website while nothing is committed to the official GitHub repo or pushed to Vercel. I will only commit to GitHub when the app is ready.",
                "We can still work on the website while nothing is committed to the official GitHub repo or pushed to Vercel. I will only commit to GitHub when the app is ready."),
 "m_deepgram": ("So Murmur currently uses the local engines, but there is one speech to text from Deepgram. That would mean we are using AI transcription in the cloud, is that right?",
                "So Murmur currently uses the local engines, but there is one speech to text from Deepgram. That would mean we are using AI transcription in the cloud, is that right?"),
 "m_model":    ("Where did we get this model from? Is this from a GitHub repo or any other open source place? There should be documents about it that we can research.",
                "Where did we get this model from? Is this from a GitHub repo or any other open source place? There should be documents about it that we can research."),
 "m_hero":     ("The hero section uses a different font. It should use the same Manrope font as the app, and the pill should appear before the cleaned up text.",
                "The hero section uses a different font. It should use the same Manrope font as the app, and the pill should appear before the cleaned up text."),
 "m_dots":     ("In the progress view, when you click into the habit, the dots that represent each day are too big. They should be smaller.",
                "In the progress view, when you click into the habit, the dots that represent each day are too big. They should be smaller."),
 "m_filler":   ("So, um, where do we use Manrope, and, uh, what other font can we use with it?",
                "So, where do we use Manrope, and what other font can we use with it?"),
 "m_parakeet": ("Parakeet is faster, but whisper.cpp gets the names right, so we need to test both on the same recordings.",
                "Parakeet is faster, but whisper.cpp gets the names right, so we need to test both on the same recordings."),
 # long (past 30 seconds once spoken, with the key held after)
 "l_research": ("Yesterday I did some research on recognition engines and which models this other app uses. The outcome was that the other app uses the built-in Apple engine and Whisper models, and it works really well. It builds the architecture so that the end result is the best possible for the user. When they speak, they get back what they said, and they don't have to go back and change it all the time.",
                "Yesterday I did some research on recognition engines and which models this other app uses. The outcome was that the other app uses the built-in Apple engine and Whisper models, and it works really well. It builds the architecture so that the end result is the best possible for the user. When they speak, they get back what they said, and they don't have to go back and change it all the time."),
 "l_banner":   ("Next thing, Flit has a banner claiming these features, so you can look up Wispr Flow and the other ones, where it says how much time you save, how many words you would be typing, and how many words you can say on average. We will not mention how many languages it covers, but we will say that it's four times faster and that zero bytes of audio leave your Mac.",
                "Next thing, Flit has a banner claiming these features, so you can look up Wispr Flow and the other ones, where it says how much time you save, how many words you would be typing, and how many words you can say on average. We will not mention how many languages it covers, but we will say that it's four times faster and that zero bytes of audio leave your Mac."),
 "l_navbar":   ("Next up is also a critical component, the navigation bar that pops up from the bottom of the screen. It needs to be redesigned in the same way as the HUD pill and the notch. There are also some critical edge cases in this navigation bar, because depending on which direction you come from, some of the options can be selected, and it has to be very simple and intuitive to use.",
                "Next up is also a critical component, the navigation bar that pops up from the bottom of the screen. It needs to be redesigned in the same way as the HUD pill and the notch. There are also some critical edge cases in this navigation bar, because depending on which direction you come from, some of the options can be selected, and it has to be very simple and intuitive to use."),
 "l_copy":     ("For the copy on the website, the story about Murmur and its features, research the live app to understand what it actually does, how it transcribes the text, and how each mode changes the result. All the animations should match the actual app. Then take the color palette from the live app as well, and use it or improve it on the website.",
                "For the copy on the website, the story about Murmur and its features, research the live app to understand what it actually does, how it transcribes the text, and how each mode changes the result. All the animations should match the actual app. Then take the color palette from the live app as well, and use it or improve it on the website."),
}
VOICES = {  # Deepgram Aura-2
 "asteria": "aura-2-asteria-en",   # American, female
 "zeus": "aura-2-zeus-en",         # American, male
 "draco": "aura-2-draco-en",       # British, male
 "julius": "aura-2-julius-de",     # German speaker reading English
 "lars": "aura-2-lars-nl",         # Dutch speaker reading English
 "cesare": "aura-2-cesare-it",     # Italian speaker reading English
}
