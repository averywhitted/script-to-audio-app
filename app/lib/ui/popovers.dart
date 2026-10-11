// Line-editing popovers. Contract: popovers[].

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

const _kindLabels = ['Dialog', 'Narration'];
const _kindValues = ['dialog', 'stage_direction'];

Widget _label(Tokens t, String s) => Padding(
  padding: const EdgeInsets.only(bottom: 5),
  child: Text(
    s,
    style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: t.muted),
  ),
);

List<String> _speakerOptions(AppState app, String current, {bool includeNarrator = false}) {
  final opts = <String>[if (includeNarrator) 'Narrator', ...?app.script?.characters.map((c) => c.name)];
  if (current.isNotEmpty && current != 'Narrator' && !opts.contains(current)) opts.insert(0, current);
  return opts;
}

SelectField<String> _speakerPicker(AppState app, String value, List<String> options, ValueChanged<String> onChanged) => SelectField<String>(
  label: value.isEmpty ? 'Choose speaker' : titleCaseName(value),
  placeholder: value.isEmpty,
  leading: value.isEmpty ? null : SpeakerDot(value, allSpeakers: app.allSpeakers, size: 8),
  items: [for (final o in options) MenuItemSpec(o, titleCaseName(o), checked: o == value)],
  onSelected: onChanged,
);

/// "Correct this line"
class CorrectLinePopover extends StatefulWidget {
  const CorrectLinePopover({super.key, required this.sceneNumber, required this.element});
  final int sceneNumber;
  final SceneElement element;
  @override
  State<CorrectLinePopover> createState() => _CorrectLinePopoverState();
}

class _CorrectLinePopoverState extends State<CorrectLinePopover> {
  late String kind;
  late String speaker;
  late final TextEditingController text;
  late final TextEditingController t0;
  late final TextEditingController t1;
  late bool removed;
  late final String _origKind, _origSpeaker, _origText, _o0, _o1;
  late final bool _origRemoved;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final el = widget.element;
    final fix = app.correctionFor(widget.sceneNumber, el);
    kind = fix?.correctedKind ?? el.kind;
    if (kind == 'parenthetical') kind = 'stage_direction';
    final s = fix?.correctedSpeaker ?? el.speaker ?? '';
    speaker = s.isEmpty ? '' : s;
    text = TextEditingController(text: (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText : el.text);
    final ot = fix?.correctedOverlapTexts ?? el.overlapTexts ?? const <String>[];
    t0 = TextEditingController(text: ot.isNotEmpty ? ot[0] : el.text);
    t1 = TextEditingController(text: ot.length > 1 ? ot[1] : el.text);
    removed = fix?.markedAsNoise ?? false;
    _origKind = kind;
    _origSpeaker = speaker;
    _origText = text.text;
    _o0 = t0.text;
    _o1 = t1.text;
    _origRemoved = removed;
  }

  bool get _changed => kind != _origKind || speaker != _origSpeaker || text.text != _origText || t0.text != _o0 || t1.text != _o1 || removed != _origRemoved;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final el = widget.element;
    final split = el.hasSplitText && (el.overlapCue?.length ?? 0) >= 2;
    final hasCorrection = app.correctionFor(widget.sceneNumber, el) != null;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Correct this line', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 14),
          _label(t, 'Type'),
          Segmented(
            labels: _kindLabels,
            selected: _kindValues.indexOf(kind).clamp(0, 1),
            width: double.infinity,
            onChanged: (i) => setState(() => kind = _kindValues[i]),
          ),
          if (kind == 'dialog' && !split) ...[
            const SizedBox(height: 12),
            _label(t, 'Speaker'),
            _speakerPicker(app, speaker, _speakerOptions(app, speaker, includeNarrator: true), (v) => setState(() => speaker = v)),
          ],
          const SizedBox(height: 12),
          if (split) ...[
            _label(t, 'Lines (simultaneous)'),
            for (final (i, c) in [(0, t0), (1, t1)]) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: NameChip(el.overlapCue![i], allSpeakers: app.allSpeakers, uppercase: true),
              ),
              Field(controller: c, maxLines: 4, minLines: 2, mono: true, onChanged: (_) => setState(() {})),
              const SizedBox(height: 8),
            ],
          ] else ...[
            _label(t, 'Text'),
            Field(controller: text, maxLines: 6, minLines: 3, mono: true, onChanged: (_) => setState(() {})),
          ],
          const SizedBox(height: 12),
          Pill(
            removed ? 'Restore this line' : 'Remove this line',
            icon: removed ? Icons.undo_rounded : Icons.remove_circle_outline_rounded,
            bg: removed ? t.ctrl : t.dangerSoft,
            fg: removed ? t.ink2 : t.danger,
            onTap: () => setState(() => removed = !removed),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (hasCorrection)
                Btn(
                  'Undo Changes',
                  kind: BtnKind.plain,
                  small: true,
                  onPressed: () {
                    app.deleteCorrection(widget.sceneNumber, el);
                    Navigator.of(context).pop();
                  },
                ),
              const Spacer(),
              Btn('Cancel', small: true, onPressed: () => Navigator.of(context).pop()),
              const SizedBox(width: 8),
              Btn(
                'Save',
                kind: BtnKind.primary,
                small: true,
                onPressed: _changed
                    ? () {
                        app.correctLine(
                          widget.sceneNumber,
                          el,
                          kind: kind,
                          speaker: speaker.isEmpty ? null : speaker,
                          text: split ? null : text.text,
                          overlapTexts: split ? [t0.text, t1.text] : null,
                          removed: removed,
                        );
                        Navigator.of(context).pop();
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Edit added line"
class EditAddedLinePopover extends StatefulWidget {
  const EditAddedLinePopover({super.key, required this.sceneNumber, required this.element});
  final int sceneNumber;
  final UserAddedElement element;
  @override
  State<EditAddedLinePopover> createState() => _EditAddedLinePopoverState();
}

class _EditAddedLinePopoverState extends State<EditAddedLinePopover> {
  late String kind = widget.element.kind == 'dialog' ? 'dialog' : 'stage_direction';
  late String speaker = widget.element.speaker.isEmpty ? 'Narrator' : widget.element.speaker;
  late final text = TextEditingController(text: widget.element.text);

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit added line', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 14),
          _label(t, 'Type'),
          Segmented(
            labels: _kindLabels,
            selected: _kindValues.indexOf(kind).clamp(0, 1),
            width: double.infinity,
            onChanged: (i) => setState(() => kind = _kindValues[i]),
          ),
          if (kind == 'dialog') ...[
            const SizedBox(height: 12),
            _label(t, 'Speaker'),
            _speakerPicker(app, speaker, _speakerOptions(app, speaker, includeNarrator: true), (v) => setState(() => speaker = v)),
          ],
          const SizedBox(height: 12),
          _label(t, 'Text'),
          Field(controller: text, maxLines: 6, minLines: 3, mono: true, autofocus: true, onChanged: (_) => setState(() {})),
          const SizedBox(height: 16),
          Row(
            children: [
              const Spacer(),
              Btn('Cancel', small: true, onPressed: () => Navigator.of(context).pop()),
              const SizedBox(width: 8),
              Btn(
                'Save',
                kind: BtnKind.primary,
                small: true,
                onPressed: text.text.trim().isEmpty
                    ? null
                    : () {
                        app.updateAddedLine(
                          widget.sceneNumber,
                          widget.element.id,
                          speaker: kind == 'stage_direction' ? '' : speaker,
                          text: text.text.trim(),
                          kind: kind,
                        );
                        Navigator.of(context).pop();
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Edit line" — one voice of a simultaneous pair.
class EditVoicePopover extends StatefulWidget {
  const EditVoicePopover({super.key, required this.sceneNumber, required this.element, required this.voiceIndex, this.manualPair});
  final int sceneNumber;
  final SceneElement element;
  final int voiceIndex;

  /// For pairs the user made: edit that line's own correction instead.
  final SceneElement? manualPair;
  @override
  State<EditVoicePopover> createState() => _EditVoicePopoverState();
}

class _EditVoicePopoverState extends State<EditVoicePopover> {
  late String speaker;
  late final TextEditingController text;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    final el = widget.element;
    final fix = app.correctionFor(widget.sceneNumber, el);
    if (widget.manualPair != null) {
      final s = fix?.correctedSpeaker ?? el.speaker ?? '';
      speaker = s.isEmpty ? 'Narrator' : s;
      text = TextEditingController(text: (fix?.correctedText?.isNotEmpty ?? false) ? fix!.correctedText : el.text);
    } else {
      final cue = fix?.correctedOverlapSpeakers ?? el.overlapCue ?? const <String>[];
      final texts = fix?.correctedOverlapTexts ?? el.overlapTexts ?? const <String>[];
      speaker = widget.voiceIndex < cue.length ? cue[widget.voiceIndex] : '';
      text = TextEditingController(text: widget.voiceIndex < texts.length ? texts[widget.voiceIndex] : el.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit line', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 14),
          _label(t, 'Speaker'),
          _speakerPicker(app, speaker, _speakerOptions(app, speaker, includeNarrator: widget.manualPair != null), (v) => setState(() => speaker = v)),
          const SizedBox(height: 12),
          _label(t, 'Line'),
          Field(controller: text, maxLines: 6, minLines: 3, mono: true),
          const SizedBox(height: 16),
          Row(
            children: [
              const Spacer(),
              Btn('Cancel', small: true, onPressed: () => Navigator.of(context).pop()),
              const SizedBox(width: 8),
              Btn(
                'Save',
                kind: BtnKind.primary,
                small: true,
                onPressed: () {
                  if (widget.manualPair != null) {
                    app.correctLine(
                      widget.sceneNumber,
                      widget.element,
                      kind: 'dialog',
                      speaker: speaker,
                      text: text.text,
                      removed: app.correctionFor(widget.sceneNumber, widget.element)?.markedAsNoise ?? false,
                    );
                  } else {
                    app.editOverlapVoice(widget.sceneNumber, widget.element, widget.voiceIndex, speaker, text.text);
                  }
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Change speaker" from the multi-select bar.
class ChangeSpeakerPopover extends StatefulWidget {
  const ChangeSpeakerPopover({super.key, required this.lineCount, required this.onApply});
  final int lineCount;
  final ValueChanged<String> onApply;
  @override
  State<ChangeSpeakerPopover> createState() => _ChangeSpeakerPopoverState();
}

class _ChangeSpeakerPopoverState extends State<ChangeSpeakerPopover> {
  String speaker = '';
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Change speaker', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          _label(t, 'Speaker'),
          _speakerPicker(app, speaker, app.allSpeakers, (v) => setState(() => speaker = v)),
          const SizedBox(height: 12),
          Btn(
            'Apply to ${widget.lineCount} line${widget.lineCount == 1 ? '' : 's'}',
            kind: BtnKind.primary,
            expand: true,
            onPressed: speaker.isEmpty
                ? null
                : () {
                    widget.onApply(speaker);
                    Navigator.of(context).pop();
                  },
          ),
        ],
      ),
    );
  }
}
