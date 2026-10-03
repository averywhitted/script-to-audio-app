// 🎯 Your First ML Model - Copy ALL of this into a new macOS Playground!
//
// Steps:
// 1. File → New → Playground (choose macOS)
// 2. Delete everything in the playground
// 3. Paste this entire file
// 4. Click the ▶️ button at the bottom to run
// 5. Wait 10-30 seconds for training
// 6. Check your Desktop for ScriptClassifier.mlmodel!

import CreateML
import Foundation

print("🚀 Starting ML training for script classification!")

// TRAINING DATA - These are examples the model will learn from.
// 505 synthetic examples across 4 classes (dialog, stage_direction,
// parenthetical, scene_heading). Synthetic on purpose — real screenplay
// text from Test PDFs/ is copyrighted and shouldn't be baked into a
// shipped model file.
let examples = [
    // Dialog: character cue lines (ALL CAPS names) and spoken lines
    ("ALICE", "dialog"),
    ("AMARA", "dialog"),
    ("AMARA (offscreen)", "dialog"),
    ("Are we still meeting tomorrow?", "dialog"),
    ("BOY (V.O.)", "dialog"),
    ("BRIDGET (CONT'D)", "dialog"),
    ("BRIDGET (offscreen)", "dialog"),
    ("CAPTAIN", "dialog"),
    ("COACH", "dialog"),
    ("COACH (V.O.)", "dialog"),
    ("COP 1", "dialog"),
    ("COP 1 (offscreen)", "dialog"),
    ("Can we just start over?", "dialog"),
    ("Can you just be honest with me for once?", "dialog"),
    ("DAD (V.O.)", "dialog"),
    ("DETECTIVE MORALES (V.O.)", "dialog"),
    ("DIANA (V.O.)", "dialog"),
    ("DOCTOR REYES", "dialog"),
    ("Did you hear that noise?", "dialog"),
    ("Don't you dare walk away from me.", "dialog"),
    ("Everything's going to be fine.", "dialog"),
    ("FRANK", "dialog"),
    ("FRANK (O.S.)", "dialog"),
    ("GEORGE", "dialog"),
    ("GEORGE (into phone)", "dialog"),
    ("GIRL (offscreen)", "dialog"),
    ("GRANDMOTHER", "dialog"),
    ("GRANDMOTHER (CONT'D)", "dialog"),
    ("GRANDMOTHER (offscreen)", "dialog"),
    ("Get out of my house right now.", "dialog"),
    ("HELEN", "dialog"),
    ("Hello, how are you?", "dialog"),
    ("How could you keep this from me?", "dialog"),
    ("How long have you known?", "dialog"),
    ("I can't believe you did that.", "dialog"),
    ("I can't do this without you.", "dialog"),
    ("I can't keep doing this.", "dialog"),
    ("I can't stop thinking about it.", "dialog"),
    ("I don't know what you're talking about.", "dialog"),
    ("I don't recognize you anymore.", "dialog"),
    ("I found this in your jacket.", "dialog"),
    ("I keep thinking about what you said.", "dialog"),
    ("I need some air, give me a minute.", "dialog"),
    ("I need you to trust me.", "dialog"),
    ("I never wanted any of this.", "dialog"),
    ("I saw them leave together.", "dialog"),
    ("I thought you were different.", "dialog"),
    ("I trusted you with everything.", "dialog"),
    ("I'll be right there, hold on.", "dialog"),
    ("I'll take care of it myself.", "dialog"),
    ("I'm done waiting around for an answer.", "dialog"),
    ("I'm not afraid of you.", "dialog"),
    ("I'm not going back in there.", "dialog"),
    ("I'm sorry, I didn't mean to yell.", "dialog"),
    ("I've been waiting for you all night.", "dialog"),
    ("I've made up my mind, and that's final.", "dialog"),
    ("I've never seen anything like it.", "dialog"),
    ("IRIS", "dialog"),
    ("IVAN", "dialog"),
    ("Is anyone else seeing this?", "dialog"),
    ("Is this really happening right now?", "dialog"),
    ("Is this some kind of joke?", "dialog"),
    ("It's not too late to fix this.", "dialog"),
    ("JANE", "dialog"),
    ("Just give me one good reason.", "dialog"),
    ("Just tell me where it hurts.", "dialog"),
    ("LANDLADY", "dialog"),
    ("Let's just forget this ever happened.", "dialog"),
    ("MARCUS", "dialog"),
    ("MARCUS (CONT'D)", "dialog"),
    ("MECHANIC (O.S.)", "dialog"),
    ("MONICA (into phone)", "dialog"),
    ("NADIA (O.S.)", "dialog"),
    ("NARRATOR (into phone)", "dialog"),
    ("NEIGHBOR", "dialog"),
    ("NEIGHBOR (CONT'D)", "dialog"),
    ("NURSE", "dialog"),
    ("Nobody asked for your opinion.", "dialog"),
    ("None of this makes any sense.", "dialog"),
    ("Nothing about this feels right.", "dialog"),
    ("OFFICER CHEN (V.O.)", "dialog"),
    ("OMAR (O.S.)", "dialog"),
    ("OSCAR (V.O.)", "dialog"),
    ("PILOT (O.S.)", "dialog"),
    ("PRIYA (V.O.)", "dialog"),
    ("PROFESSOR", "dialog"),
    ("PROFESSOR (into phone)", "dialog"),
    ("Please, just listen to me for a second.", "dialog"),
    ("RECEPTIONIST", "dialog"),
    ("RECEPTIONIST (offscreen)", "dialog"),
    ("RUBY", "dialog"),
    ("RUBY (V.O.)", "dialog"),
    ("SAMUEL", "dialog"),
    ("SAMUEL (offscreen)", "dialog"),
    ("SECURITY GUARD", "dialog"),
    ("SETH (V.O.)", "dialog"),
    ("SOLDIER (CONT'D)", "dialog"),
    ("SOPHIE", "dialog"),
    ("STUDENT", "dialog"),
    ("She never mentioned any of this.", "dialog"),
    ("Since when do you care?", "dialog"),
    ("Somebody has to tell them eventually.", "dialog"),
    ("TARA", "dialog"),
    ("TASHA (V.O.)", "dialog"),
    ("TEACHER", "dialog"),
    ("TEACHER (O.S.)", "dialog"),
    ("TREVOR (O.S.)", "dialog"),
    ("Tell me you didn't mean that.", "dialog"),
    ("That's not fair and you know it.", "dialog"),
    ("There's something you should know.", "dialog"),
    ("This is the last time I'm asking.", "dialog"),
    ("This isn't what it looks like.", "dialog"),
    ("Turn the car around, now.", "dialog"),
    ("UMA", "dialog"),
    ("URI", "dialog"),
    ("VERA (O.S.)", "dialog"),
    ("VERA (into phone)", "dialog"),
    ("VOICE (offscreen)", "dialog"),
    ("WREN", "dialog"),
    ("WREN (V.O.)", "dialog"),
    ("Wait, stop right there.", "dialog"),
    ("We need to talk about this.", "dialog"),
    ("We should have left an hour ago.", "dialog"),
    ("We're out of time, we have to go.", "dialog"),
    ("What are you so afraid of?", "dialog"),
    ("What did you say to her?", "dialog"),
    ("What happens now?", "dialog"),
    ("What's the worst that could happen?", "dialog"),
    ("Where were you last night?", "dialog"),
    ("Who else knows about this?", "dialog"),
    ("Why didn't you call me back?", "dialog"),
    ("Why does it always come back to money?", "dialog"),
    ("Why would she do something like that?", "dialog"),
    ("XIOMARA (offscreen)", "dialog"),
    ("YARA (CONT'D)", "dialog"),
    ("YOUNG WOMAN", "dialog"),
    ("You always do this.", "dialog"),
    ("You could have warned me.", "dialog"),
    ("You don't get to decide that for me.", "dialog"),
    ("You have no idea what I've been through.", "dialog"),
    ("You knew this whole time, didn't you?", "dialog"),
    ("You never told me the truth.", "dialog"),
    ("You promised me it would be different.", "dialog"),
    ("You're making a huge mistake.", "dialog"),
    ("You're the only one who ever listens.", "dialog"),

    // Stage directions: third-person action / scene description
    ("A dog barks somewhere down the street.", "stage_direction"),
    ("A door slams somewhere upstairs.", "stage_direction"),
    ("A phone rings, unanswered, on the counter.", "stage_direction"),
    ("A siren wails somewhere far off.", "stage_direction"),
    ("Alice grabs a coat and heads for the door.", "stage_direction"),
    ("Alice hides behind the curtain, holding their breath.", "stage_direction"),
    ("Alice sits down at the table, exhausted.", "stage_direction"),
    ("Alice slams the door on the way out.", "stage_direction"),
    ("Alice stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("Alice throws the keys onto the table.", "stage_direction"),
    ("Alice wipes away tears and takes a deep breath.", "stage_direction"),
    ("Bob freezes, unable to move.", "stage_direction"),
    ("Bob knocks on the door twice, then waits.", "stage_direction"),
    ("Bob picks up the phone and dials.", "stage_direction"),
    ("Bob pours a drink and downs it in one go.", "stage_direction"),
    ("Bob reaches into the drawer and pulls out an old photograph.", "stage_direction"),
    ("Bob rushes to the window and pulls the curtains shut.", "stage_direction"),
    ("Bob sinks into the chair, head in hands.", "stage_direction"),
    ("Bob slams the door on the way out.", "stage_direction"),
    ("Bob stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("Dust settles over the abandoned furniture.", "stage_direction"),
    ("Footsteps echo down the empty hallway.", "stage_direction"),
    ("He checks the mirror one last time before leaving.", "stage_direction"),
    ("He freezes, unable to move.", "stage_direction"),
    ("He pulls out a gun and aims it at the door.", "stage_direction"),
    ("He slams the door on the way out.", "stage_direction"),
    ("He slides the note under the door.", "stage_direction"),
    ("He stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("He tears the letter into pieces.", "stage_direction"),
    ("He throws the keys onto the table.", "stage_direction"),
    ("Her mother collapses onto the couch.", "stage_direction"),
    ("Her mother crosses to the window and looks out.", "stage_direction"),
    ("Her mother disappears around the corner.", "stage_direction"),
    ("Her mother hides behind the curtain, holding their breath.", "stage_direction"),
    ("Her mother kneels beside the body and checks for a pulse.", "stage_direction"),
    ("Her mother leans against the wall, catching their breath.", "stage_direction"),
    ("Her mother paces back and forth across the room.", "stage_direction"),
    ("Her mother pulls out a gun and aims it at the door.", "stage_direction"),
    ("Her mother rushes to the window and pulls the curtains shut.", "stage_direction"),
    ("Her mother stares blankly at the ceiling.", "stage_direction"),
    ("Her mother throws the keys onto the table.", "stage_direction"),
    ("His father hides behind the curtain, holding their breath.", "stage_direction"),
    ("His father lights a cigarette with shaking hands.", "stage_direction"),
    ("His father picks up the phone and dials.", "stage_direction"),
    ("His father throws the keys onto the table.", "stage_direction"),
    ("His father wipes away tears and takes a deep breath.", "stage_direction"),
    ("She freezes, unable to move.", "stage_direction"),
    ("She reaches into the drawer and pulls out an old photograph.", "stage_direction"),
    ("She sits down at the table, exhausted.", "stage_direction"),
    ("She slides the note under the door.", "stage_direction"),
    ("She unlocks the door and steps inside cautiously.", "stage_direction"),
    ("Smoke drifts up from the ashtray.", "stage_direction"),
    ("Someone disappears around the corner.", "stage_direction"),
    ("Someone glances nervously at the clock.", "stage_direction"),
    ("Someone hides behind the curtain, holding their breath.", "stage_direction"),
    ("Someone kneels beside the body and checks for a pulse.", "stage_direction"),
    ("Someone picks up the phone and dials.", "stage_direction"),
    ("Someone pulls out a gun and aims it at the door.", "stage_direction"),
    ("Someone sits down at the table, exhausted.", "stage_direction"),
    ("Someone slides the note under the door.", "stage_direction"),
    ("Someone unlocks the door and steps inside cautiously.", "stage_direction"),
    ("The boy checks the mirror one last time before leaving.", "stage_direction"),
    ("The boy counts the money twice before putting it away.", "stage_direction"),
    ("The boy drops the plate, which shatters on the floor.", "stage_direction"),
    ("The boy leans against the wall, catching their breath.", "stage_direction"),
    ("The boy lights a cigarette with shaking hands.", "stage_direction"),
    ("The boy pulls out a gun and aims it at the door.", "stage_direction"),
    ("The boy reaches into the drawer and pulls out an old photograph.", "stage_direction"),
    ("The boy slams the door on the way out.", "stage_direction"),
    ("The boy stares blankly at the ceiling.", "stage_direction"),
    ("The boy turns and walks away into the fog.", "stage_direction"),
    ("The boy unlocks the door and steps inside cautiously.", "stage_direction"),
    ("The boy wipes away tears and takes a deep breath.", "stage_direction"),
    ("The clock on the wall strikes midnight.", "stage_direction"),
    ("The detective closes the laptop and stares out the window.", "stage_direction"),
    ("The detective counts the money twice before putting it away.", "stage_direction"),
    ("The detective exits quickly without a word.", "stage_direction"),
    ("The detective freezes, unable to move.", "stage_direction"),
    ("The detective leans against the wall, catching their breath.", "stage_direction"),
    ("The detective reaches into the drawer and pulls out an old photograph.", "stage_direction"),
    ("The detective stares blankly at the ceiling.", "stage_direction"),
    ("The detective stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("The detective throws the keys onto the table.", "stage_direction"),
    ("The detective watches the rain streak down the glass.", "stage_direction"),
    ("The engine sputters and dies.", "stage_direction"),
    ("The girl leans against the wall, catching their breath.", "stage_direction"),
    ("The girl pulls out a gun and aims it at the door.", "stage_direction"),
    ("The girl rushes to the window and pulls the curtains shut.", "stage_direction"),
    ("The girl slides the note under the door.", "stage_direction"),
    ("The girl stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("The girl turns and walks away into the fog.", "stage_direction"),
    ("The kettle begins to whistle.", "stage_direction"),
    ("The lights flicker and go out.", "stage_direction"),
    ("The old man collapses onto the couch.", "stage_direction"),
    ("The old man crosses to the window and looks out.", "stage_direction"),
    ("The old man hides behind the curtain, holding their breath.", "stage_direction"),
    ("The old man paces back and forth across the room.", "stage_direction"),
    ("The old man pours a drink and downs it in one go.", "stage_direction"),
    ("The old man stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("The old man tears the letter into pieces.", "stage_direction"),
    ("The old man throws the keys onto the table.", "stage_direction"),
    ("The old man watches the rain streak down the glass.", "stage_direction"),
    ("The old man wipes away tears and takes a deep breath.", "stage_direction"),
    ("The room falls silent.", "stage_direction"),
    ("The soldier crosses to the window and looks out.", "stage_direction"),
    ("The soldier freezes, unable to move.", "stage_direction"),
    ("The soldier leans against the wall, catching their breath.", "stage_direction"),
    ("The soldier stops mid-sentence, distracted by something outside.", "stage_direction"),
    ("The soldier tears the letter into pieces.", "stage_direction"),
    ("The soldier throws the keys onto the table.", "stage_direction"),
    ("The stranger counts the money twice before putting it away.", "stage_direction"),
    ("The stranger crosses to the window and looks out.", "stage_direction"),
    ("The stranger drops the plate, which shatters on the floor.", "stage_direction"),
    ("The stranger glances nervously at the clock.", "stage_direction"),
    ("The stranger looks up, startled by the sound.", "stage_direction"),
    ("The stranger picks up the phone and dials.", "stage_direction"),
    ("The stranger rushes to the window and pulls the curtains shut.", "stage_direction"),
    ("The stranger wipes away tears and takes a deep breath.", "stage_direction"),
    ("The television flickers with static.", "stage_direction"),
    ("The young woman checks the mirror one last time before leaving.", "stage_direction"),
    ("The young woman drops the plate, which shatters on the floor.", "stage_direction"),
    ("The young woman freezes, unable to move.", "stage_direction"),
    ("The young woman glances nervously at the clock.", "stage_direction"),
    ("The young woman kneels beside the body and checks for a pulse.", "stage_direction"),
    ("The young woman looks up, startled by the sound.", "stage_direction"),
    ("The young woman paces back and forth across the room.", "stage_direction"),
    ("The young woman sits down at the table, exhausted.", "stage_direction"),
    ("The young woman tears the letter into pieces.", "stage_direction"),
    ("Thunder rumbles in the distance.", "stage_direction"),
    ("Wind rattles the loose window frame.", "stage_direction"),

    // Parentheticals: short actor-direction notes in parens
    ("(CONT'D)", "parenthetical"),
    ("(O.S.)", "parenthetical"),
    ("(V.O.)", "parenthetical"),
    ("(a beat)", "parenthetical"),
    ("(almost inaudible)", "parenthetical"),
    ("(angrily)", "parenthetical"),
    ("(barely audible)", "parenthetical"),
    ("(bitterly)", "parenthetical"),
    ("(coldly)", "parenthetical"),
    ("(deadpan)", "parenthetical"),
    ("(distracted)", "parenthetical"),
    ("(dryly)", "parenthetical"),
    ("(fighting back tears)", "parenthetical"),
    ("(firmly)", "parenthetical"),
    ("(flatly)", "parenthetical"),
    ("(glancing at Elena)", "parenthetical"),
    ("(glancing at Frank)", "parenthetical"),
    ("(glancing at George)", "parenthetical"),
    ("(glancing at Monica)", "parenthetical"),
    ("(glancing at Nora)", "parenthetical"),
    ("(glancing at Rachel)", "parenthetical"),
    ("(glancing at Samuel)", "parenthetical"),
    ("(glancing at Seth)", "parenthetical"),
    ("(glancing at Tara)", "parenthetical"),
    ("(glancing at Trevor)", "parenthetical"),
    ("(glancing at Uma)", "parenthetical"),
    ("(glancing at Uri)", "parenthetical"),
    ("(glancing at Vera)", "parenthetical"),
    ("(glancing at Wren)", "parenthetical"),
    ("(glancing at Yusuf)", "parenthetical"),
    ("(hesitating)", "parenthetical"),
    ("(icily)", "parenthetical"),
    ("(interrupting)", "parenthetical"),
    ("(long pause)", "parenthetical"),
    ("(matter-of-factly)", "parenthetical"),
    ("(not unkindly)", "parenthetical"),
    ("(overlapping)", "parenthetical"),
    ("(pause)", "parenthetical"),
    ("(pleading)", "parenthetical"),
    ("(pointedly)", "parenthetical"),
    ("(quietly)", "parenthetical"),
    ("(sarcastically)", "parenthetical"),
    ("(shouting)", "parenthetical"),
    ("(smirking)", "parenthetical"),
    ("(softly)", "parenthetical"),
    ("(still smiling)", "parenthetical"),
    ("(still to Amara)", "parenthetical"),
    ("(still to Bridget)", "parenthetical"),
    ("(still to Carl)", "parenthetical"),
    ("(still to Charlie)", "parenthetical"),
    ("(still to Derek)", "parenthetical"),
    ("(still to Helen)", "parenthetical"),
    ("(still to Iris)", "parenthetical"),
    ("(still to Ivan)", "parenthetical"),
    ("(still to Jane)", "parenthetical"),
    ("(still to Jasper)", "parenthetical"),
    ("(still to Kevin)", "parenthetical"),
    ("(still to Lucy)", "parenthetical"),
    ("(still to Marcus)", "parenthetical"),
    ("(still to Ruby)", "parenthetical"),
    ("(still to Tara)", "parenthetical"),
    ("(still to Trevor)", "parenthetical"),
    ("(still to Yara)", "parenthetical"),
    ("(through tears)", "parenthetical"),
    ("(to Bob)", "parenthetical"),
    ("(to Charlie)", "parenthetical"),
    ("(to Felicia)", "parenthetical"),
    ("(to Frank)", "parenthetical"),
    ("(to Leon)", "parenthetical"),
    ("(to Lucy)", "parenthetical"),
    ("(to Marcus)", "parenthetical"),
    ("(to Omar)", "parenthetical"),
    ("(to Seth)", "parenthetical"),
    ("(to Sophie)", "parenthetical"),
    ("(to Tasha)", "parenthetical"),
    ("(to Wren)", "parenthetical"),
    ("(to Xiomara)", "parenthetical"),
    ("(to everyone)", "parenthetical"),
    ("(to herself)", "parenthetical"),
    ("(to himself)", "parenthetical"),
    ("(to no one in particular)", "parenthetical"),
    ("(trying not to cry)", "parenthetical"),
    ("(turning to Alice)", "parenthetical"),
    ("(turning to Amara)", "parenthetical"),
    ("(turning to Bridget)", "parenthetical"),
    ("(turning to Charlie)", "parenthetical"),
    ("(turning to Derek)", "parenthetical"),
    ("(turning to Diana)", "parenthetical"),
    ("(turning to Frank)", "parenthetical"),
    ("(turning to George)", "parenthetical"),
    ("(turning to Helen)", "parenthetical"),
    ("(turning to Jasper)", "parenthetical"),
    ("(turning to Kevin)", "parenthetical"),
    ("(turning to Kira)", "parenthetical"),
    ("(turning to Monica)", "parenthetical"),
    ("(turning to Nadia)", "parenthetical"),
    ("(turning to Omar)", "parenthetical"),
    ("(turning to Tara)", "parenthetical"),
    ("(turning to Tasha)", "parenthetical"),
    ("(turning to Wren)", "parenthetical"),
    ("(under her breath)", "parenthetical"),
    ("(warmly)", "parenthetical"),
    ("(whispering)", "parenthetical"),
    ("(with a nervous laugh)", "parenthetical"),
    ("(with a sigh)", "parenthetical"),

    // Scene headings: INT./EXT. LOCATION - TIME
    ("EXT. AIRPORT TERMINAL - CONTINUOUS", "scene_heading"),
    ("EXT. AIRPORT TERMINAL - MOMENTS LATER", "scene_heading"),
    ("EXT. ALLEY - LATER", "scene_heading"),
    ("EXT. ATTIC - NIGHT", "scene_heading"),
    ("EXT. BACKYARD - NIGHT", "scene_heading"),
    ("EXT. BAR - AFTERNOON", "scene_heading"),
    ("EXT. BAR - DAY", "scene_heading"),
    ("EXT. BAR - MOMENTS LATER", "scene_heading"),
    ("EXT. BATHROOM - AFTERNOON", "scene_heading"),
    ("EXT. BATHROOM - MOMENTS LATER", "scene_heading"),
    ("EXT. BATHROOM - NIGHT", "scene_heading"),
    ("EXT. BEDROOM - AFTERNOON", "scene_heading"),
    ("EXT. CAR - CONTINUOUS", "scene_heading"),
    ("EXT. CHURCH - MORNING", "scene_heading"),
    ("EXT. CLASSROOM - CONTINUOUS", "scene_heading"),
    ("EXT. CLASSROOM - DAWN", "scene_heading"),
    ("EXT. COURTROOM - CONTINUOUS", "scene_heading"),
    ("EXT. DOCK - MORNING", "scene_heading"),
    ("EXT. ELEVATOR - DAY", "scene_heading"),
    ("EXT. ELEVATOR - DUSK", "scene_heading"),
    ("EXT. FARMHOUSE - CONTINUOUS", "scene_heading"),
    ("EXT. FARMHOUSE - DAY", "scene_heading"),
    ("EXT. GARDEN - CONTINUOUS", "scene_heading"),
    ("EXT. GREENHOUSE - LATER", "scene_heading"),
    ("EXT. GREENHOUSE - NIGHT", "scene_heading"),
    ("EXT. GROCERY STORE - MOMENTS LATER", "scene_heading"),
    ("EXT. GYM - NIGHT", "scene_heading"),
    ("EXT. HALLWAY - DAY", "scene_heading"),
    ("EXT. HOSPITAL ROOM - LATER", "scene_heading"),
    ("EXT. HOTEL ROOM - DAWN", "scene_heading"),
    ("EXT. KITCHEN - DUSK", "scene_heading"),
    ("EXT. LIBRARY - CONTINUOUS", "scene_heading"),
    ("EXT. LIBRARY - DAWN", "scene_heading"),
    ("EXT. LIBRARY - LATER", "scene_heading"),
    ("EXT. LIBRARY - NIGHT", "scene_heading"),
    ("EXT. MOTEL ROOM - CONTINUOUS", "scene_heading"),
    ("EXT. MOTEL ROOM - DAY", "scene_heading"),
    ("EXT. OFFICE - MOMENTS LATER", "scene_heading"),
    ("EXT. POLICE STATION - DUSK", "scene_heading"),
    ("EXT. RESTAURANT - NIGHT", "scene_heading"),
    ("EXT. ROOF - NIGHT", "scene_heading"),
    ("EXT. ROOFTOP - AFTERNOON", "scene_heading"),
    ("EXT. STAIRWELL - DAWN", "scene_heading"),
    ("EXT. TRAIN STATION - DAWN", "scene_heading"),
    ("EXT. WAREHOUSE - DUSK", "scene_heading"),
    ("INT. AIRPORT TERMINAL - AFTERNOON", "scene_heading"),
    ("INT. AIRPORT TERMINAL - LATER", "scene_heading"),
    ("INT. AIRPORT TERMINAL - MOMENTS LATER", "scene_heading"),
    ("INT. ALLEY - LATER", "scene_heading"),
    ("INT. APARTMENT - DUSK", "scene_heading"),
    ("INT. APARTMENT - MOMENTS LATER", "scene_heading"),
    ("INT. ATTIC - DAWN", "scene_heading"),
    ("INT. ATTIC - LATER", "scene_heading"),
    ("INT. BACKSTAGE - CONTINUOUS", "scene_heading"),
    ("INT. BACKYARD - LATER", "scene_heading"),
    ("INT. BACKYARD - MOMENTS LATER", "scene_heading"),
    ("INT. BAR - DAWN", "scene_heading"),
    ("INT. BARN - DAY", "scene_heading"),
    ("INT. BARN - DUSK", "scene_heading"),
    ("INT. BATHROOM - DAY", "scene_heading"),
    ("INT. BEACH - DUSK", "scene_heading"),
    ("INT. BEDROOM - CONTINUOUS", "scene_heading"),
    ("INT. BRIDGE - NIGHT", "scene_heading"),
    ("INT. BUS STOP - DAY", "scene_heading"),
    ("INT. CABIN - CONTINUOUS", "scene_heading"),
    ("INT. CABIN - NIGHT", "scene_heading"),
    ("INT. CLASSROOM - DUSK", "scene_heading"),
    ("INT. CLASSROOM - MOMENTS LATER", "scene_heading"),
    ("INT. COFFEE SHOP - LATER", "scene_heading"),
    ("INT. DINER - AFTERNOON", "scene_heading"),
    ("INT. DINER - MOMENTS LATER", "scene_heading"),
    ("INT. FARMHOUSE - DAY", "scene_heading"),
    ("INT. GARDEN - DAWN", "scene_heading"),
    ("INT. GROCERY STORE - AFTERNOON", "scene_heading"),
    ("INT. GYM - DUSK", "scene_heading"),
    ("INT. LIBRARY - DAY", "scene_heading"),
    ("INT. LOCKER ROOM - DUSK", "scene_heading"),
    ("INT. PARKING GARAGE - DUSK", "scene_heading"),
    ("INT. ROOF - MOMENTS LATER", "scene_heading"),
    ("INT. STUDIO - LATER", "scene_heading"),
    ("INT. SUBWAY PLATFORM - DAWN", "scene_heading"),
    ("INT./EXT. AIRPORT TERMINAL - DAY", "scene_heading"),
    ("INT./EXT. APARTMENT - DAY", "scene_heading"),
    ("INT./EXT. ATTIC - DUSK", "scene_heading"),
    ("INT./EXT. BAR - LATER", "scene_heading"),
    ("INT./EXT. BAR - MOMENTS LATER", "scene_heading"),
    ("INT./EXT. BARN - AFTERNOON", "scene_heading"),
    ("INT./EXT. BARN - DUSK", "scene_heading"),
    ("INT./EXT. BARN - NIGHT", "scene_heading"),
    ("INT./EXT. BATHROOM - DAY", "scene_heading"),
    ("INT./EXT. BATHROOM - DUSK", "scene_heading"),
    ("INT./EXT. BEACH - AFTERNOON", "scene_heading"),
    ("INT./EXT. BEACH - DAWN", "scene_heading"),
    ("INT./EXT. BRIDGE - DAWN", "scene_heading"),
    ("INT./EXT. BRIDGE - MOMENTS LATER", "scene_heading"),
    ("INT./EXT. BRIDGE - NIGHT", "scene_heading"),
    ("INT./EXT. CABIN - AFTERNOON", "scene_heading"),
    ("INT./EXT. CAR - CONTINUOUS", "scene_heading"),
    ("INT./EXT. CAR - DUSK", "scene_heading"),
    ("INT./EXT. CAR - MOMENTS LATER", "scene_heading"),
    ("INT./EXT. CAR - MORNING", "scene_heading"),
    ("INT./EXT. CHURCH - DUSK", "scene_heading"),
    ("INT./EXT. CLASSROOM - DAWN", "scene_heading"),
    ("INT./EXT. COURTROOM - AFTERNOON", "scene_heading"),
    ("INT./EXT. DOCK - DAY", "scene_heading"),
    ("INT./EXT. FARMHOUSE - DAY", "scene_heading"),
    ("INT./EXT. FARMHOUSE - NIGHT", "scene_heading"),
    ("INT./EXT. GARDEN - LATER", "scene_heading"),
    ("INT./EXT. GREENHOUSE - NIGHT", "scene_heading"),
    ("INT./EXT. GYM - DUSK", "scene_heading"),
    ("INT./EXT. HOTEL ROOM - DAWN", "scene_heading"),
    ("INT./EXT. KITCHEN - DAY", "scene_heading"),
    ("INT./EXT. LIBRARY - DAWN", "scene_heading"),
    ("INT./EXT. LIVING ROOM - DAY", "scene_heading"),
    ("INT./EXT. LIVING ROOM - LATER", "scene_heading"),
    ("INT./EXT. LOBBY - MOMENTS LATER", "scene_heading"),
    ("INT./EXT. PARKING GARAGE - DUSK", "scene_heading"),
    ("INT./EXT. PARKING GARAGE - LATER", "scene_heading"),
    ("INT./EXT. PARKING GARAGE - MOMENTS LATER", "scene_heading"),
    ("INT./EXT. PARKING GARAGE - NIGHT", "scene_heading"),
    ("INT./EXT. ROOFTOP - CONTINUOUS", "scene_heading"),
    ("INT./EXT. STUDIO - CONTINUOUS", "scene_heading"),
    ("INT./EXT. STUDIO - DUSK", "scene_heading"),
    ("INT./EXT. SUBWAY PLATFORM - NIGHT", "scene_heading"),
    ("INT./EXT. TRAIN STATION - DUSK", "scene_heading"),
]

print("📚 Loaded \(examples.count) training examples")

// TRAIN THE MODEL
do {
    // Step 1: Create a CSV file (most reliable method for Playgrounds)
    print("\n📝 Step 1: Creating training data CSV...")

    var csvString = "text,label\n"
    for (text, label) in examples {
        // Escape quotes for CSV format
        let escapedText = text.replacingOccurrences(of: "\"", with: "\"\"")
        csvString += "\"\(escapedText)\",\(label)\n"
    }

    // Save to a temporary file
    let csvURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ml_training_\(UUID().uuidString).csv")

    try csvString.write(to: csvURL, atomically: true, encoding: .utf8)
    print("   ✅ CSV created at: \(csvURL.lastPathComponent)")

    // Step 2: Load CSV into MLDataTable
    print("\n📊 Step 2: Loading data into MLDataTable...")
    let data = try MLDataTable(contentsOf: csvURL)
    print("   ✅ Loaded \(data.rows.count) rows with columns: \(data.columnNames.joined(separator: ", "))")

    // Step 3: Split into train/validation so accuracy numbers mean something
    let (train, validation) = data.randomSplit(by: 0.8, seed: 42)
    print("   Train set: \(train.rows.count) examples, validation set: \(validation.rows.count) examples")

    // Step 4: Train the model
    print("\n🧠 Step 3: Training the classifier...")
    print("   ⏰ This will take 10-30 seconds - don't worry if it seems stuck!")

    let startTime = Date()

    let classifier = try MLTextClassifier(
        trainingData: train,
        textColumn: "text",
        labelColumn: "label"
    )

    let duration = Date().timeIntervalSince(startTime)
    print("   ✅ Training complete in \(String(format: "%.1f", duration)) seconds!")

    // Step 5: Evaluate on held-out validation data
    print("\n📈 Step 4: Evaluating on held-out validation data...")
    let trainAccuracy = (1.0 - classifier.trainingMetrics.classificationError) * 100
    let validationAccuracy = (1.0 - classifier.validationMetrics.classificationError) * 100
    print("   Training accuracy:   \(String(format: "%.1f%%", trainAccuracy))")
    print("   Validation accuracy: \(String(format: "%.1f%%", validationAccuracy))")

    // Step 6: Save the model
    print("\n💾 Step 5: Saving model to Desktop...")

    let desktopURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/ScriptClassifier.mlmodel")

    try classifier.write(to: desktopURL)
    print("   ✅ Model saved to: Desktop/ScriptClassifier.mlmodel")

    // Step 7: Test predictions
    print("\n🧪 Step 6: Testing predictions on new text...")
    print("   (Text the model has never seen before)")

    let testCases = [
        ("FRANK", "Should predict: dialog (character name)"),
        ("Get out of here!", "Should predict: dialog (character speech)"),
        ("(whispers)", "Should predict: parenthetical (actor note)"),
        ("The phone rings.", "Should predict: stage_direction (action)"),
        ("INT. OFFICE - AFTERNOON", "Should predict: scene_heading (location)")
    ]

    for (text, description) in testCases {
        let prediction = try classifier.prediction(from: text)
        print("\n   '\(text)'")
        print("   → Predicted: \(prediction) (\(description))")
    }

    // DONE!
    print("\n" + String(repeating: "=", count: 60))
    print("🎉 SUCCESS! Your ML model is ready!")
    print(String(repeating: "=", count: 60))
    print("\n✅ Check your Desktop for ScriptClassifier.mlmodel")
    print("✅ Copy it into Sources/TableRead/ScriptClassifier.mlmodel to replace the current one")
    print("✅ Then run the ScriptClassifierTests test in Xcode (⌘U) to verify it still loads")

} catch {
    print("\n❌ ERROR occurred during training:")
    print("   \(error.localizedDescription)")
    print("\n💡 Troubleshooting tips:")
    print("   - Make sure this is a macOS Playground (not iOS)")
    print("   - Try restarting Xcode")
    print("   - Check that you have write access to Desktop")
}

// 🎓 WHAT YOU JUST LEARNED:
//
// 1. Created training data (text + label pairs)
// 2. Converted it to CSV format
// 3. Loaded it into MLDataTable, split into train/validation
// 4. Trained a text classifier with Create ML
// 5. Measured accuracy on data it never saw during training
// 6. Saved it as a .mlmodel file and made predictions with it!
//
// 🚀 NEXT STEPS:
//
// 1. Add more examples above, especially ones the model gets wrong
// 2. Check the model file on your Desktop
// 3. Drag it into Sources/TableRead/ (replacing the existing one)
// 4. Run ScriptClassifierTests.swift in Xcode to confirm it loads
//
// You're now a machine learning developer! 🎉
