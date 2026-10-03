#!/usr/bin/env python3
"""Regenerates the synthetic training set used in SimpleMLPlayground.swift.

Templated/combinatorial, not real screenplay text (Test PDFs/ is copyrighted
and shouldn't end up baked into a shipped .mlmodel). Edit the word lists or
templates below and rerun to get a different/larger dataset, then paste
`training_data.json` (or the printed Swift literal) back into
SimpleMLPlayground.swift and ml/MyPlayground.playground/Contents.swift.

Usage:
    python3 generate_training_data.py
    # writes training_data.json next to this script
"""
import random
import json
from collections import Counter

random.seed(42)

# ---- Character cues (dialog: the ALL-CAPS speaker line) ----
first_names = [
    "ALICE","BOB","CHARLIE","DIANA","FRANK","GEORGE","HELEN","IVAN","JANE","KEVIN",
    "LUCY","MARCUS","NADIA","OSCAR","PRIYA","QUENTIN","RACHEL","SAMUEL","TASHA","URI",
    "VERA","WALTER","XIOMARA","YUSUF","ZOE","ELENA","DEREK","MONICA","TREVOR","AMARA",
    "CARL","SOPHIE","LEON","BRIDGET","OMAR","FELICIA","HANK","IRIS","JASPER","KIRA",
    "NORA","PAUL","QUINN","RUBY","SETH","TARA","UMA","VINCE","WREN","YARA"
]
role_names = [
    "NARRATOR","DETECTIVE MORALES","OLD MAN","YOUNG WOMAN","WAITER","DOCTOR REYES",
    "MOM","DAD","TEACHER","STRANGER","GUARD #1","GUARD #2","JUDGE","NURSE","BARTENDER",
    "CLERK","DRIVER","OFFICER CHEN","LANDLADY","PRIEST","COACH","RECEPTIONIST","MECHANIC",
    "STUDENT","SOLDIER","WAITRESS","PROFESSOR","CAPTAIN","MAYOR","BABYSITTER","PILOT",
    "COP 1","COP 2","VOICE","ANNOUNCER","BOY","GIRL","GRANDMOTHER","GRANDFATHER",
    "NEIGHBOR","SECURITY GUARD"
]
cue_suffixes = ["", "", "", "", " (V.O.)", " (O.S.)", " (CONT'D)", " (into phone)", " (offscreen)"]

def make_cue():
    name = random.choice(first_names + role_names)
    return (name + random.choice(cue_suffixes)).strip()

# ---- Dialogue lines (mixed case, spoken text) ----
dialogue_templates = [
    "Hello, how are you{q}",
    "I can't believe you did that{p}",
    "Wait, stop right there{p}",
    "What did you say to her{q}",
    "I'm not going back in there{p}",
    "We need to talk about this{p}",
    "Did you hear that noise{q}",
    "This isn't what it looks like{p}",
    "I've been waiting for you all night{p}",
    "You never told me the truth{p}",
    "Get out of my house right now{p}",
    "I don't know what you're talking about{p}",
    "Please, just listen to me for a second{p}",
    "Where were you last night{q}",
    "That's not fair and you know it{p}",
    "I'm sorry, I didn't mean to yell{p}",
    "Can we just start over{q}",
    "You're making a huge mistake{p}",
    "I found this in your jacket{p}",
    "Nobody asked for your opinion{p}",
    "How long have you known{q}",
    "I thought you were different{p}",
    "Turn the car around, now{p}",
    "I've never seen anything like it{p}",
    "Why didn't you call me back{q}",
    "This is the last time I'm asking{p}",
    "You have no idea what I've been through{p}",
    "Is anyone else seeing this{q}",
    "I need you to trust me{p}",
    "Don't you dare walk away from me{p}",
    "It's not too late to fix this{p}",
    "I keep thinking about what you said{p}",
    "Are we still meeting tomorrow{q}",
    "She never mentioned any of this{p}",
    "I'll be right there, hold on{p}",
    "You promised me it would be different{p}",
    "I can't do this without you{p}",
    "Since when do you care{q}",
    "Everything's going to be fine{p}",
    "I saw them leave together{p}",
    "What are you so afraid of{q}",
    "Just tell me where it hurts{p}",
    "I'm done waiting around for an answer{p}",
    "You could have warned me{p}",
    "Is this some kind of joke{q}",
    "We're out of time, we have to go{p}",
    "I never wanted any of this{p}",
    "Who else knows about this{q}",
    "I trusted you with everything{p}",
    "Let's just forget this ever happened{p}",
    "You don't get to decide that for me{p}",
    "How could you keep this from me{q}",
    "I need some air, give me a minute{p}",
    "None of this makes any sense{p}",
    "Why does it always come back to money{q}",
    "I've made up my mind, and that's final{p}",
    "Somebody has to tell them eventually{p}",
    "You're the only one who ever listens{p}",
    "What happens now{q}",
    "I can't keep doing this{p}",
    "Just give me one good reason{p}",
    "You knew this whole time, didn't you{q}",
    "I'll take care of it myself{p}",
    "Nothing about this feels right{p}",
    "Can you just be honest with me for once{q}",
    "I don't recognize you anymore{p}",
    "We should have left an hour ago{p}",
    "Is this really happening right now{q}",
    "I'm not afraid of you{p}",
    "There's something you should know{p}",
    "Why would she do something like that{q}",
    "I can't stop thinking about it{p}",
    "You always do this{p}",
    "Tell me you didn't mean that{p}",
    "What's the worst that could happen{q}",
]
def make_dialogue():
    t = random.choice(dialogue_templates)
    return t.format(q="?", p=".")

# ---- Stage directions (third person action) ----
# Keep subjects animate/singular so they agree with the singular-conjugated
# verbs in direction_templates below (no "They picks up...").
subjects = ["He","She","The old man","The young woman","Alice","Bob","The stranger",
            "The detective","Someone","The boy","The girl","Her mother","His father","The soldier"]
direction_templates = [
    "{s} crosses to the window and looks out.",
    "{s} exits quickly without a word.",
    "{s} slams the door on the way out.",
    "{s} sits down at the table, exhausted.",
    "{s} glances nervously at the clock.",
    "{s} pulls out a gun and aims it at the door.",
    "{s} stares blankly at the ceiling.",
    "{s} picks up the phone and dials.",
    "{s} freezes, unable to move.",
    "{s} turns and walks away into the fog.",
    "{s} lights a cigarette with shaking hands.",
    "{s} collapses onto the couch.",
    "{s} rushes to the window and pulls the curtains shut.",
    "{s} wipes away tears and takes a deep breath.",
    "{s} reaches into the drawer and pulls out an old photograph.",
    "{s} paces back and forth across the room.",
    "{s} knocks on the door twice, then waits.",
    "{s} disappears around the corner.",
    "{s} drops the plate, which shatters on the floor.",
    "{s} pours a drink and downs it in one go.",
    "{s} looks up, startled by the sound.",
    "{s} kneels beside the body and checks for a pulse.",
    "{s} grabs a coat and heads for the door.",
    "{s} stops mid-sentence, distracted by something outside.",
    "{s} sinks into the chair, head in hands.",
    "{s} watches the rain streak down the glass.",
    "{s} tears the letter into pieces.",
    "{s} hides behind the curtain, holding their breath.",
    "{s} counts the money twice before putting it away.",
    "{s} throws the keys onto the table.",
    "{s} leans against the wall, catching their breath.",
    "{s} checks the mirror one last time before leaving.",
    "{s} slides the note under the door.",
    "{s} closes the laptop and stares out the window.",
    "{s} unlocks the door and steps inside cautiously.",
    "Thunder rumbles in the distance.",
    "The lights flicker and go out.",
    "A door slams somewhere upstairs.",
    "Rain begins to fall against the window.",
    "The room falls silent.",
    "A phone rings, unanswered, on the counter.",
    "The engine sputters and dies.",
    "Footsteps echo down the empty hallway.",
    "The clock on the wall strikes midnight.",
    "Smoke drifts up from the ashtray.",
    "A siren wails somewhere far off.",
    "The television flickers with static.",
    "Wind rattles the loose window frame.",
    "A dog barks somewhere down the street.",
    "The kettle begins to whistle.",
    "Dust settles over the abandoned furniture.",
]
def make_direction():
    t = random.choice(direction_templates)
    return t.format(s=random.choice(subjects)) if "{s}" in t else t

# ---- Parentheticals ----
parenthetical_fixed = [
    "(softly)","(beat)","(laughing)","(angrily)","(quietly)","(pause)","(whispering)",
    "(shouting)","(sarcastically)","(matter-of-factly)","(to no one in particular)",
    "(under his breath)","(through tears)","(with a sigh)","(coldly)","(gently)","(interrupting)",
    "(still smiling)","(V.O.)","(O.S.)","(CONT'D)","(hesitating)","(smirking)","(deadpan)",
    "(trying not to cry)","(barely audible)","(with a nervous laugh)","(firmly)","(pleading)",
    "(to herself)","(to himself)","(bitterly)","(warmly)","(flatly)","(teasing)",
    "(under breath)","(distracted)","(overlapping)","(with a shrug)","(dryly)","(icily)",
    "(under her breath)","(fighting back tears)","(a beat)","(long pause)","(to everyone)",
    "(without looking up)","(not unkindly)","(almost inaudible)","(with forced calm)","(pointedly)",
]
def make_fixed_parenthetical():
    return random.choice(parenthetical_fixed)

def make_addressed_parenthetical():
    name = random.choice(first_names)
    style = random.choice(["to {n}", "turning to {n}", "still to {n}", "glancing at {n}"])
    return "(" + style.format(n=name.capitalize()) + ")"

def make_parenthetical():
    return make_fixed_parenthetical() if random.random() < 0.55 else make_addressed_parenthetical()

# ---- Scene headings ----
int_ext = ["INT.","EXT.","INT./EXT."]
locations = [
    "COFFEE SHOP","APARTMENT","HOSPITAL ROOM","POLICE STATION","FOREST CLEARING",
    "SUBWAY PLATFORM","ROOFTOP","CLASSROOM","KITCHEN","BEDROOM","PARKING GARAGE",
    "DINER","LIBRARY","CHURCH","BACKSTAGE","GYM","OFFICE","ELEVATOR","ALLEY","BRIDGE",
    "MOTEL ROOM","CAR","BASEMENT","ATTIC","GARDEN","BEACH","TRAIN STATION","BAR",
    "COURTROOM","HALLWAY","LIVING ROOM","BATHROOM","WAREHOUSE","ROOF","STAIRWELL",
    "LOBBY","BACKYARD","FARMHOUSE","CABIN","SCHOOL GYM","GROCERY STORE","BUS STOP",
    "AIRPORT TERMINAL","HOTEL ROOM","RESTAURANT","PARK","DOCK","BARN","TUNNEL","STUDIO",
    "GREENHOUSE","LOCKER ROOM",
]
times = ["DAY","NIGHT","MORNING","AFTERNOON","DUSK","DAWN","CONTINUOUS","LATER","MOMENTS LATER"]
def make_scene_heading():
    return f"{random.choice(int_ext)} {random.choice(locations)} - {random.choice(times)}"

def unique_n(fn, n, max_tries_factor=80):
    seen = set()
    out = []
    tries = 0
    while len(out) < n and tries < n * max_tries_factor:
        tries += 1
        v = fn()
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out

if __name__ == "__main__":
    cues = unique_n(make_cue, 70)
    lines = unique_n(make_dialogue, 80)
    directions = unique_n(make_direction, 130)
    parens = unique_n(make_parenthetical, 105)
    headings = unique_n(make_scene_heading, 125)

    dataset = []
    for c in cues: dataset.append((c, "dialog"))
    for l in lines: dataset.append((l, "dialog"))
    for d in directions: dataset.append((d, "stage_direction"))
    for p in parens: dataset.append((p, "parenthetical"))
    for h in headings: dataset.append((h, "scene_heading"))

    random.shuffle(dataset)

    print("Total examples:", len(dataset))
    print(Counter(label for _, label in dataset))

    with open("training_data.json", "w") as f:
        json.dump(dataset, f, indent=0)
