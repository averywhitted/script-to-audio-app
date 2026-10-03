# ScriptElementClassifier

An ML classifier that tags screenplay blocks (`dialog`, `stage_direction`,
`parenthetical`, `character_cue`, `scene_heading`, `noise`) from text **plus PDF
layout metadata**, and reports a calibrated confidence used to flag uncertain
lines for review.

## Current status

**Shipping: `shadow` mode** — the model scores every block's confidence but does
not change classification. That drives the Review ⚠ and the "N need review"
count, with provably zero effect on parse output.

**Not enabled: `hybrid` / `ml`** — they improve kind accuracy substantially on the
weakest scripts (MercuryFur 94.9→100%, AgainstTheHillside 91.4→99.9%) but no
confidence threshold is a clean win against the parser oracle, so the default
stays `heuristic`. See "Where this stands" below.

## Pipeline

```
PDF ─► backend/features.py ──► 45 document-relative features per block
                                (FEATURE_SCHEMA_VERSION gates compatibility)
        │
        ├─ ml/build_dataset.py      align blocks to Test PDFs/reference/*_independent.json
        │                            by text signature → ml/data/dataset.csv (20,989 rows)
        ├─ ml/train_element_classifier.py
        │                            leave-one-script-out CV, calibration gate,
        │                            export → ml/models/script_element_classifier.json
        └─ backend/element_classifier.py
                                     pure-stdlib inference at runtime
```

### Commands

```bash
pip install -r requirements-ml.txt        # training deps only; nothing ships

python ml/build_dataset.py                # rebuild training data from ground truth
python ml/train_element_classifier.py     # LOSO eval + calibration + export + parity
python ml/train_element_classifier.py --eval-only
python ml/make_fixtures.py --check        # verify feature extraction hasn't drifted

python scripts/scorecard.py --mode shadow --check   # A/B a mode vs the oracle
python scripts/ml_report.py EMMA --errors           # per-block forensics
python scripts/ml_report.py --paren-audit           # cross-script label consistency
python scripts/ml_smoke.py                          # unlabelled-script smoke test
TABLEREAD_ML_THRESHOLD=0.9 python scripts/scorecard.py --mode hybrid --check
```

## Design decisions worth knowing

**Every feature is document-relative.** No raw coordinate reaches the model —
positions are fractions of page size or signed offsets from the document's own
learned columns (`speaker_x`/`dialog_x`/`stage_dir_x`). An absolute x baked into
model weights is a global constant in disguise, which is the documented cause of
four earlier parser rewrites failing (see CLAUDE.md's parser protocol).

**No open-class vocabulary.** The model sees structural text properties (caps
ratio, word count, paren/punctuation shape, INT./EXT. and (V.O.) regex flags) and
closed-class pronoun person — *not* the words themselves. Dialogue is not a
vocabulary; "Hello" and "Wherefore art thou" are both dialogue, so bag-of-words
mostly learns character names and fails on the next script. It also keeps
copyrighted script text out of a shipped artefact.

**JSON model, not CoreML.** coremltools 9 caps scikit-learn at 1.5.1 and has no
wheels for the 3.14 dev interpreter — but more fundamentally, the app runs the
parser on the bundled CPython 3.12 in `vendor/python`, where scikit-learn would
add ~100 MB. A random forest is an average of leaf distributions, so
`backend/element_classifier.py` evaluates it in ~100 lines of stdlib.
`--check-parity` asserts it reproduces scikit-learn exactly (0 label mismatches,
6e-08 max confidence delta).

*If you port this to Swift:* compare feature values in **Float (32-bit)**, not
Double. scikit-learn casts X to float32 before tree traversal while thresholds
stay float64; matching in float64 flips branches near splits and cost ~5e-3 of
confidence error before it was fixed.

**Leave-one-script-out is the only honest number.** Train on 6 scripts, test on
the 7th, rotate. Training and testing on the same corpus reports memorisation.

## Where this stands

LOSO: **91.4% pooled, macro F1 0.768.**

| class | F1 | note |
|---|---|---|
| character_cue | 0.982 | strong |
| dialog | 0.926 | strong |
| noise | 0.864 | |
| parenthetical | 0.743 | was 0.23 before a corpus label fix |
| scene_heading | 0.571 | only 52 examples — unreliable |
| stage_direction | 0.520 | **weak**; 854 dialogs misread as stage_direction |

**Calibration gate PASSED** — accuracy is 65.2% below confidence 0.70 vs 100% at
≥0.90 (34.7-point separation). Threshold 0.60 flags 14% of lines, 45% of which are
genuinely wrong, catching 74% of all errors. This is what justifies the review
flag; had confidence not predicted wrongness, the flag would have been noise that
trains users to ignore warnings, and should not have shipped.

### Known limitations

- `stage_direction` vs `dialog` is the dominant remaining confusion. The tuned
  heuristic is better here, which is why hybrid mode is off.
- On scripts outside the corpus the flag rate rises to 16–35% (vs ~12% inside),
  i.e. the model is less certain on unfamiliar formats. 35% is too noisy to act
  on — see `scripts/ml_smoke.py`.
- `character_cue`, `scene_heading` and `noise` labels are derived from the parser
  itself, so the model can match but never beat the parser on those classes.
- `scene_heading` has 52 training examples across the whole corpus.

### Ground-truth defects found while building this

Fixed in `ml/build_dataset.py`, but they are defects in
`Test PDFs/reference/*_independent.json` and worth fixing at source:

1. **MercuryFur labels bare page numbers as `stage_direction`** (signatures
   "1".."9"), which imported 166 bogus examples — >10% contamination of that
   script's SD class.
2. **MercuryFur and AgainstTheHillside have no `parenthetical` category at all**;
   MercuryFur files 504 bracketed asides under `stage_direction`. The other five
   scripts distinguish them. Run `python scripts/ml_report.py --paren-audit`.
3. The oracle's 4-character signature floor hides **35% of dialog, 40% of stage
   directions and 64% of parentheticals** from any signature-based matching —
   all short lines, which is where classification is hardest.
