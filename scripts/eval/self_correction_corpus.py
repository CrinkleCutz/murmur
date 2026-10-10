"""Labelled cases for spoken self-correction ("5pm, actually 6pm" -> "6pm").

Positives are built by construction (context + retracted + cue + repair + tail -> context + repair + tail), so the
expected output is exact; hand-written cases cover phrase-level repairs. Negatives must come out UNCHANGED.
`build_corpus()` returns [{id, cat, input, expected, hard}]; run this file to print a summary.
"""
import collections, random


def build_corpus():
    rnd = random.Random(20260920)
    rows = []

    def add(cat, inp, exp, hard=False):
        rows.append({"id": f"{cat}:{len(rows)}", "cat": cat, "input": inp, "expected": exp, "hard": hard})

    cues = [("actually", ", ", ", "), ("no actually", ", ", ", "), ("no wait", ", ", ", "), ("wait no", ", ", ", "), ("sorry", ", ", ", "),
            ("I mean", ", ", " "), ("or rather", ", ", " "), ("actually", " ", " "), ("no wait", " ", " "), ("make that", ", ", " "),
            ("actually make it", ", ", " "), ("sorry I meant", ", ", " ")]
    strong = [c for c in cues if c[0] in ("no wait", "wait no", "sorry", "I mean", "or rather", "make that", "sorry I meant")]
    time = [("5pm", "6pm"), ("5 p.m.", "6 p.m."), ("3:30", "4:30"), ("five", "six"), ("9 a.m.", "10 a.m."), ("10:15", "10:30"), ("7", "8"),
            ("2", "3"), ("noon", "1pm"), ("5:00 p.m.", "6:00 p.m."), ("half past five", "half past six")]
    time_ctx = [("Let's meet at", " works better for everyone."), ("The call is at", " today."), ("Book the room for", "."),
                ("I'll be there at", " sharp."), ("Let's do coffee at", "."), ("Set the alarm for", " tomorrow.")]
    day = [("Friday", "Monday"), ("Tuesday", "Wednesday"), ("tomorrow", "Thursday"), ("the 5th", "the 6th"), ("March 5th", "March 6th"),
           ("June 12", "June 14"), ("Sunday", "Saturday")]
    day_ctx = [("Let's ship on", " instead."), ("The meeting is on", "."), ("We launch", " at noon."), ("Send the invoice by", ".")]
    num = [("three tickets", "four tickets"), ("20", "25"), ("$5,000", "$6,000"), ("50 dollars", "60 dollars"), ("ten", "twelve"),
           ("15 percent", "20 percent"), ("two", "three"), ("100", "150")]
    num_ctx = [("I need", " for the trip."), ("We ordered", " yesterday."), ("It costs", "."), ("The budget is", " this quarter.")]
    name = [("John", "Mary"), ("Sarah", "Sam"), ("Paris", "London"), ("Anna", "Peter")]
    name_ctx = [("Send it to", " for review."), ("Tell", " about the launch."), ("I'll ask", " to check it.")]

    def sample(vals, ctxs, cue_set, n, cat):
        for _ in range(n):
            v1, v2 = rnd.choice(vals); pre, post = rnd.choice(ctxs); c, a, b = rnd.choice(cue_set)
            add(cat, f"{pre} {v1}{a}{c}{b}{v2}{post}", f"{pre} {v2}{post}")

    sample(time, time_ctx, cues, 26, "time"); sample(day, day_ctx, cues, 16, "day"); sample(num, num_ctx, cues, 20, "number")
    sample(name, name_ctx, strong, 12, "name")

    for c, i, e in [
        ("value", "Call John at 3pm, actually make it 4pm, and tell him Tuesday, actually Wednesday works.", "Call John at 4pm, and tell him Wednesday works."),
        ("value", "The deadline is 5pm on Monday, no sorry, 6pm on Monday.", "The deadline is 6pm on Monday."),
        ("value", "We need 20 licenses, actually 25.", "We need 25 licenses."),
        ("value", "Let's do coffee at 2 actually 3.", "Let's do coffee at 3."),
        ("value", "Let's meet at 5 pm, no actually 6 pm.", "Let's meet at 6 pm."),
        ("value", "Dinner is at seven, or rather eight, at the new place.", "Dinner is at eight, at the new place."),
        ("value", "The release is next Friday, actually next Monday.", "The release is next Monday."),
        ("value", "The meeting is at 5pm in the big room, actually 6pm.", "The meeting is at 6pm in the big room."),
        ("value", "I'll send it Tuesday, wait, Wednesday morning.", "I'll send it Wednesday morning."),
        ("value", "It's due on the 3rd, no wait, the 4th of May.", "It's due on the 4th of May."),
        ("value", "Please invite 12 people, sorry, 14 people to the workshop.", "Please invite 14 people to the workshop."),
        ("value", "The flight leaves at 7:45, actually 8:15 in the morning.", "The flight leaves at 8:15 in the morning."),
    ]:
        add(c, i, e)

    for r in [
        ("phrase", "Let's ship on Friday, actually let's ship on Monday instead.", "Let's ship on Monday instead."),
        ("phrase", "Send it to John, no wait, send it to Mary.", "Send it to Mary."),
        ("phrase", "Use Postgres, actually use Redis for the cache.", "Use Redis for the cache."),
        ("phrase", "We should refactor the login page, sorry, the signup page first.", "We should refactor the signup page first."),
        ("phrase", "The button should be blue, no wait, green.", "The button should be green."),
        ("phrase", "I'd like the red one, sorry, the blue one.", "I'd like the blue one."),
        ("phrase", "Open the settings page, I mean the profile page, and check the name.", "Open the profile page, and check the name."),
        ("phrase", "We should test the API, actually we should test the UI first.", "We should test the UI first."),
        ("phrase", "Add it to the header, no wait, to the footer.", "Add it to the footer."),
        ("phrase", "Put the logo on the left, sorry, on the right side.", "Put the logo on the right side."),
        ("phrase", "Tell Sarah, actually tell everyone on the team.", "Tell everyone on the team."),
        ("phrase", "I need to deploy to the prod. Sorry, I mean the staging environment.", "I need to deploy to the staging environment."),
        ("phrase", "Send it to John. No wait, send it to Mary.", "Send it to Mary."),
        ("phrase", "Let's order pizza, wait, scratch that, let's order sushi.", "Let's order sushi."),
        ("phrase", "We can do the meeting in the Friday 5pm. No, actually do on Tuesday.", "We can do the meeting on Tuesday."),
        ("phrase", "Let's meet at 5pm. No, actually let's do 6pm.", "Let's meet at 6pm."),
        ("phrase", "Schedule it for Friday, no, actually do Tuesday.", "Schedule it for Tuesday."),
        ("restate", "We can do the meeting on the Friday 5pm, no, actually do that Tuesday 5pm.", "We can do the meeting on the Tuesday 5pm."),
        ("restate", "We can do the meeting on the Friday 5PM, scratch that, do that on Tuesday.", "We can do the meeting on the Tuesday 5PM."),
        ("restate", "We can do the meeting on the Friday 5PM, scratch that do that on Tuesday", "We can do the meeting on the Tuesday 5PM"),
        ("restate", "Let's meet Friday at 3pm, no wait, do it on Monday.", "Let's meet Monday at 3pm."),
        ("restate", "Let's meet Friday at 3pm, no wait, do it Monday.", "Let's meet Monday at 3pm."),
        ("restate", "The call is Tuesday at 10am, no wait, do it on Wednesday.", "The call is Wednesday at 10am."),
        ("restate", "We can do the meeting on Friday at 3pm, no wait, do that on Monday at 4pm.", "We can do the meeting on Monday at 4pm."),
        ("restate", "Let's meet Friday at 3pm, scratch that, do it on Monday.", "Let's meet Monday at 3pm."),
        ("restate", "Let's meet on the 5th at 3pm, no wait, do it on the 6th.", "Let's meet on the 6th at 3pm."),
        ("phrase", "Can we meet Tuesday, I'd rather meet Wednesday?", "Can we meet Wednesday?", True),
        ("phrase", "Ship it Friday, actually let's ship on Monday instead.", "Let's ship on Monday instead.", True),
        ("phrase", "I wanted to buy a record as a gift, as a present.", "I wanted to buy a record as a present.", True),
    ]:
        add(r[0], r[1], r[2], hard=len(r) > 3)


    # Natural corrections of shapes the resolver's rules were not written around — the model's territory.
    for i, e in [
        ("Let's have the review on the Monday 3pm, no, actually have it Wednesday 3pm.", "Let's have the review on the Wednesday 3pm."),
        ("I'll send the report on the 5th, sorry, I'll send it on the 7th.", "I'll send the report on the 7th."),
        ("Book two rooms for Friday, no wait, book three rooms for Friday.", "Book three rooms for Friday."),
        ("The client is in Paris, actually the client is in London.", "The client is in London."),
        ("Use the blue header, no wait, use the green header.", "Use the green header."),
        ("Send the invoice to Anna, sorry, to Peter's team.", "Send the invoice to Peter's team."),
        ("We need to hire a designer, actually a developer.", "We need to hire a developer."),
        ("Let's use React, no, actually let's go with Svelte for this one.", "Let's use Svelte for this one."),
        ("I want the report by Tuesday morning, I mean Wednesday morning.", "I want the report by Wednesday morning."),
        ("Call me at two, no, make that call me at three thirty.", "Call me at three thirty."),
        ("The meeting is in room 4, sorry, room 5B.", "The meeting is in room 5B."),
        ("Add a button to the top, no, to the bottom of the page.", "Add a button to the bottom of the page."),
        ("Set the limit to 100 requests, actually 200 requests per minute.", "Set the limit to 200 requests per minute."),
        ("We launch in March, wait, in April.", "We launch in April."),
        ("Ask Sam to review it, no, ask Priya to review it.", "Ask Priya to review it."),
        ("The bug is in the login form, actually it's in the signup form.", "The bug is in the signup form."),
        ("Order the large pizza, sorry, the medium pizza.", "Order the medium pizza."),
        ("Move the standup to nine, no wait, ten.", "Move the standup to ten."),
        ("Put the file in the shared folder, no, on the desktop.", "Put the file on the desktop."),
        ("We should meet in the morning, no, actually do that in the afternoon.", "We should meet in the afternoon."),
        ("I'll take the train on Thursday, sorry, I'll drive on Thursday.", "I'll drive on Thursday."),
        ("The invoice is for Acme, no wait, for Globex Corporation.", "The invoice is for Globex Corporation."),
        ("Create a new branch called feature login, no, called fix login.", "Create a new branch called fix login."),
        ("Reply to Maria today, actually tomorrow morning.", "Reply to Maria tomorrow morning."),
    ]:
        add("stress", i, e)

    for n in [
        "I actually enjoyed the movie more than I expected.", "I mean it, this is really important.", "Sorry for the delay, I was in a meeting.",
        "There is no wait time at the restaurant.", "We'll do that instead of the other plan.", "I'd rather have coffee than tea.",
        "Please don't scratch that surface.", "The meeting is at 5pm and the dinner is at 7pm.", "We can meet Friday or Monday, whichever works.",
        "Actually, that's a great idea.", "It's actually 6pm now, not 5pm.", "From 5pm to 6pm, actually the whole afternoon is booked.",
        "Tuesday, actually, is our busiest day.", "Let's meet Friday, actually Monday too.", "I have 3 kids, actually 2 boys and 1 girl.",
        "The call is at 5pm, actually let me check my calendar first.", "He said sorry and left.", "I mean, what does the future mean?",
        "The budget is 5,000 dollars and the stretch goal is 8,000 dollars.", "We shipped on Friday and fixed it on Monday.",
        "Wait, are we meeting at 5pm?", "No wait time was quoted for the 6pm slot.", "That's actually the correct answer.",
        "Sorry, I can't make it on Friday.", "Do you mean Tuesday or Wednesday?", "Call John and Mary about the 5pm slot.",
        "Send it to John, and Mary should get a copy too.", "We use Postgres and Redis together.", "Meet me at 5pm, sorry about the short notice.",
        "I'll be there at six, and actually I'm bringing lunch.", "Rather than 5pm, we should pick something later.",
        "Let's ship on Friday, actually that's the plan we agreed on.", "I was late. Sorry, I was stuck in traffic.",
        "He is late. Actually, he is on his way.", "We shipped it. Sorry, we shipped the wrong build.", "It works. Actually, it works better than I expected.",
        "The button should be blue and the header should be green.", "Open the settings page and check the profile page too.",
        "Actually it works fine on my machine.", "I said Tuesday, and the invoice says Wednesday.", "We need 20 licenses for the team and 25 for contractors.",
        "What I mean is that we need more time.", "He arrived at 5pm and left at 6pm.", "I was going to say Monday but Tuesday is better.",
        "Scratch paper is on the desk.", "I mean, it's fine either way.", "You can call me at 5pm or 6pm.", "The client wants it Monday, no rush though.",
        "It's 5 p.m. now, so let's wrap up.", "If you can't make Friday, Monday works too.",
        "We can do the meeting on the Friday 5pm. Actually, do you want Tuesday 5pm?", "We meet Friday 5pm. Sorry, do that.",
        "Book it for Friday 5pm. No, actually do that Monday too.",
        "The call is at 5pm. Actually, do 6pm work for you?", "No, actually do you know what time it closes?", "We meet in the morning. No, actually do on Tuesday.",
    ]:
        add("negative", n, n)
    return rows


if __name__ == "__main__":
    rows = build_corpus()
    print(len(rows), "cases:", dict(collections.Counter(r["cat"] for r in rows)))
