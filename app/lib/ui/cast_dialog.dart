// Cast dialog: engine, voices, previews. Opened after the first parse and from the Cast tool button.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';
import 'empty_art.dart';
import 'sheets.dart';

class _OpenAISetup extends StatefulWidget {
  const _OpenAISetup();
  @override
  State<_OpenAISetup> createState() => _OpenAISetupState();
}

class _OpenAISetupState extends State<_OpenAISetup> {
  final key = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.read<AppState>();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('OpenAI Setup', style: TextStyles.ui(t, size: 14, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_upload_outlined, size: 15, color: t.warn),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "OpenAI voices are made on OpenAI's servers: the text of every line they read is sent to OpenAI. macOS and Kokoro voices never leave this Mac.",
                  style: TextStyles.ui(t, size: 12, color: t.warn, height: 1.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Field(controller: key, placeholder: 'API key', obscure: true),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('Saved securely in Keychain and restored on next launch.', style: TextStyles.ui(t, size: 11.5, color: t.muted)),
              ),
              const SizedBox(width: 8),
              Btn(
                'Save Key',
                kind: BtnKind.primary,
                small: true,
                onPressed: () async {
                  await app.saveOpenAIKey(key.text);
                  key.clear();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({required this.name, required this.characterKey, required this.hint, required this.lines, this.first = false});
  final String name;
  final String characterKey;
  final String? hint;
  final int lines;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final voiceId = app.voiceAssignment[characterKey];
    final voice = app.voices.where((v) => v.id == voiceId).firstOrNull;
    final gender = app.effectiveGender(characterKey, hint);
    final ready = app.installedEngines.contains(app.selectedEngine);
    final male = app.voices.where((v) => v.gender == 'M').toList();
    final female = app.voices.where((v) => v.gender == 'F').toList();
    final other = app.voices.where((v) => v.gender != 'M' && v.gender != 'F').toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: t.rule)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 190,
            child: Row(
              children: [
                Flexible(child: NameChip(name == 'Narrator' ? 'NARRATOR' : name, allSpeakers: app.allSpeakers, uppercase: true, size: 11)),
                const SizedBox(width: 8),
                Text('$lines line${lines == 1 ? '' : 's'}', style: TextStyles.ui(t, size: 11.5, color: t.muted)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Segmented(
            small: true,
            labels: const ['Male', 'Female', 'Neutral'],
            selected: switch (gender) {
              'M' => 0,
              'F' => 1,
              _ => 2,
            },
            onChanged: (i) => app.setCharacterGender(['M', 'F', 'N'][i], characterKey),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectField<String>(
              label: voice?.display ?? 'Choose voice',
              placeholder: voice == null,
              items: [
                if (male.isNotEmpty) ...[const MenuItemSpec.header('Male'), for (final v in male) MenuItemSpec(v.id, v.display, checked: v.id == voiceId)],
                if (female.isNotEmpty) ...[
                  const MenuItemSpec.header('Female'),
                  for (final v in female) MenuItemSpec(v.id, v.display, checked: v.id == voiceId),
                ],
                if (other.isNotEmpty) ...[const MenuItemSpec.header('Other'), for (final v in other) MenuItemSpec(v.id, v.display, checked: v.id == voiceId)],
              ],
              onSelected: (id) => app.assignVoice(characterKey, id),
            ),
          ),
          const SizedBox(width: 8),
          if (ready) _PreviewButton(voice: voice) else const SizedBox(width: 24),
        ],
      ),
    );
  }
}

class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.voice});
  final VoiceSummary? voice;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final v = voice;
    final preparing = v != null && app.preparingPreviewVoiceId == v.id;
    final playing = v != null && app.previewingVoiceId == v.id;
    final enabled = v != null && app.preparingPreviewVoiceId == null && !app.isGenerating;
    return Tooltip(
      message: v == null ? 'Choose a voice before previewing' : 'Preview ${v.label}',
      child: Hover(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (context, h) => GestureDetector(
          onTap: enabled || playing ? () => app.toggleVoicePreview(v) : null,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: h && enabled ? t.accentSoft : t.ctrl, shape: BoxShape.circle),
            child: preparing
                ? const Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 1.6))
                : Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 15, color: enabled || playing ? t.accent : t.faint),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

Future<void> showCastSheet(BuildContext context) => showSheet(context, (_) => const _CastSheet(), width: 720);

class _CastSheet extends StatefulWidget {
  const _CastSheet();
  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    if (app.voices.isEmpty && !app.isFetchingVoices) app.fetchVoices();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final installed = app.installedEngines.contains(app.selectedEngine);
    final counts = app.lineCounts;
    final chars = List.of(app.script?.characters ?? const <CharacterSummary>[])..sort((a, b) => (counts[b.name] ?? 0).compareTo(counts[a.name] ?? 0));
    return SizedBox(
      height: 640,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 22, 26, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cast Your Voices', style: TextStyles.display(t, size: 24)),
                const SizedBox(height: 4),
                Text('Pick a voice engine, listen to the voices, and give each character one.', style: TextStyles.ui(t, color: t.ink2)),
                const SizedBox(height: 14),
                Row(
                  children: [for (final e in EngineKind.values) Expanded(child: _EngineCard(engine: e))],
                ),
              ],
            ),
          ),
          if (!installed && app.selectedEngine.isSupported)
            Container(
              margin: const EdgeInsets.fromLTRB(26, 0, 26, 10),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 15, color: t.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${app.selectedEngine.title} not installed — go to Settings to set it up.', style: TextStyles.ui(t, size: 12.5, color: t.ink2)),
                  ),
                  Btn('Open Settings', small: true, onPressed: () => showSettingsSheet(context, initialTab: 1)),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(26, 0, 26, 16),
              children: [
                if (app.selectedEngine == EngineKind.openAI) const _OpenAISetup(),
                if (app.isFetchingVoices && app.voices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Column(
                      children: [
                        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2)),
                        const SizedBox(height: 12),
                        Text('Loading voices…', style: TextStyles.ui(t, color: t.muted)),
                      ],
                    ),
                  )
                else if (app.voices.isEmpty)
                  installed
                      ? EmptyState(compact: true, art: EmptyArt.chair, title: 'No voices found for ${app.selectedEngine.title}.')
                      : const EmptyState(
                          compact: true,
                          art: EmptyArt.chair,
                          title: 'No voice engine installed yet.',
                          message: 'Install one in Settings → Engines.',
                        )
                else
                  Panel(
                    child: Column(
                      children: [
                        _VoiceRow(name: 'Narrator', characterKey: narratorKey, hint: null, lines: counts[narratorKey] ?? 0, first: true),
                        for (final c in chars) _VoiceRow(name: c.name, characterKey: c.name, hint: c.genderHint, lines: counts[c.name] ?? 0),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(26, 12, 26, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.rule)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('You can change voices any time from Cast at the top of the window.', style: TextStyles.ui(t, size: 12, color: t.muted)),
                ),
                Btn(
                  'Done',
                  kind: BtnKind.primary,
                  onPressed: () {
                    app.confirmCast();
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.engine});
  final EngineKind engine;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final selected = app.selectedEngine == engine;
    final installed = app.installedEngines.contains(engine);
    final enabled = engine.isSupported;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Hover(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (context, h) => GestureDetector(
          onTap: enabled ? () => app.selectEngine(engine) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            decoration: BoxDecoration(
              color: selected ? t.accentSoft : (h && enabled ? t.ctrl : t.sheet),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: selected ? t.accent : t.border, width: selected ? 1.5 : 1),
            ),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    engine.title,
                    style: TextStyles.ui(t, weight: FontWeight.w700, color: selected ? t.accent : t.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    !enabled ? 'Coming soon' : (installed ? engine.subtitle : 'Not installed'),
                    maxLines: 2,
                    style: TextStyles.ui(t, size: 11, color: installed || !enabled ? t.muted : t.warn),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
