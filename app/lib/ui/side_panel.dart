// Side panel: Cast · Render · Rehearse · Log. Contract: screens[sidePanel].

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../state/player_state.dart';
import '../theme/tokens.dart';
import 'dashboard.dart' show blockText;
import 'empty_art.dart';
import 'sheets.dart';
import 'widgets.dart';

enum SideTab { cast, render, rehearse, log }

class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.tab, required this.onTab});
  final SideTab tab;
  final ValueChanged<SideTab> onTab;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final logAlert = app.debugLog.any((e) => e.style == LogStyle.error || e.style == LogStyle.warning);
    const labels = ['Cast', 'Render', 'Rehearse', 'Log'];
    return Container(
      color: t.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: t.ctrl, borderRadius: BorderRadius.circular(9)),
              child: Row(
                children: [
                  for (var i = 0; i < 4; i++)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => onTab(SideTab.values[i]),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: tab.index == i ? t.ctrlOn : Colors.transparent,
                              borderRadius: BorderRadius.circular(7),
                              boxShadow: tab.index == i && !t.dark ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  labels[i],
                                  style: TextStyles.ui(
                                    t,
                                    size: 12.5,
                                    weight: tab.index == i ? FontWeight.w700 : FontWeight.w500,
                                    color: tab.index == i ? t.accent : t.muted,
                                  ),
                                ),
                                if (i == 3 && logAlert && tab != SideTab.log) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(color: t.warn, shape: BoxShape.circle),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: switch (tab) {
              SideTab.cast => const CastTab(),
              SideTab.render => const RenderTab(),
              SideTab.rehearse => const RehearseTab(),
              SideTab.log => const LogTab(),
            },
          ),
        ],
      ),
    );
  }
}

Widget _groupLabel(Tokens t, String s) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    s,
    style: TextStyles.ui(t, size: 11.5, weight: FontWeight.w600, color: t.muted),
  ),
);

// ---------------------------------------------------------------------------
// Cast
// ---------------------------------------------------------------------------

class CastTab extends StatelessWidget {
  const CastTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final installed = app.installedEngines.contains(app.selectedEngine);
    final chars = app.script?.characters ?? const <CharacterSummary>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Row(
            children: [
              Text('Engine', style: TextStyles.ui(t, color: t.muted)),
              const SizedBox(width: 10),
              Expanded(
                child: SelectField<EngineKind>(
                  label: app.selectedEngine.title,
                  items: [
                    for (final e in EngineKind.values)
                      MenuItemSpec(e, e.isSupported ? e.title : '${e.title} (coming soon)', checked: e == app.selectedEngine, enabled: e.isSupported),
                  ],
                  onSelected: app.selectEngine,
                ),
              ),
            ],
          ),
        ),
        if (!installed)
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(color: t.warnSoft, borderRadius: BorderRadius.circular(8)),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 15, color: t.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${app.selectedEngine.title} not installed — go to Settings to set it up.', style: TextStyles.ui(t, size: 12, color: t.ink2)),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
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
                      _VoiceRow(name: 'Narrator', characterKey: narratorKey, hint: null, first: true),
                      for (final c in chars) _VoiceRow(name: c.name, characterKey: c.name, hint: c.genderHint),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

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
  const _VoiceRow({required this.name, required this.characterKey, required this.hint, this.first = false});
  final String name;
  final String characterKey;
  final String? hint;
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
    final display = name == 'Narrator' ? 'Narrator' : titleCaseName(name);
    final colors = speakerColors(name, app.allSpeakers, t);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: t.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: colors.dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  display,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.ui(t, weight: FontWeight.w700),
                ),
              ),
              if (ready) _PreviewButton(voice: voice),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 16),
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
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SelectField<String>(
                    compact: true,
                    label: voice?.label ?? 'Choose voice',
                    placeholder: voice == null,
                    items: [
                      if (male.isNotEmpty) ...[
                        const MenuItemSpec.header('Male'),
                        for (final v in male) MenuItemSpec(v.id, v.display, checked: v.id == voiceId),
                      ],
                      if (female.isNotEmpty) ...[
                        const MenuItemSpec.header('Female'),
                        for (final v in female) MenuItemSpec(v.id, v.display, checked: v.id == voiceId),
                      ],
                      if (other.isNotEmpty) ...[
                        const MenuItemSpec.header('Other'),
                        for (final v in other) MenuItemSpec(v.id, v.display, checked: v.id == voiceId),
                      ],
                    ],
                    onSelected: (id) => app.assignVoice(characterKey, id),
                  ),
                ),
              ),
            ],
          ),
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

class RenderTab extends StatefulWidget {
  const RenderTab({super.key});
  @override
  State<RenderTab> createState() => _RenderTabState();
}

class _RenderTabState extends State<RenderTab> {
  bool showLog = false;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final ready = app.installedEngines.contains(app.selectedEngine);
    final canRender = !app.isGenerating && app.selectedScenes.isNotEmpty && ready;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (app.isGenerating)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: _Booth(showLog: showLog, onToggleLog: () => setState(() => showLog = !showLog)),
          ),
        if (!app.isGenerating && app.scenesNeedingRerender.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Btn(
              'Re-Render Edited Scenes (${app.scenesNeedingRerender.length})',
              kind: BtnKind.warn,
              icon: Icons.refresh_rounded,
              expand: true,
              onPressed: app.rerenderEditedScenes,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 14, 6),
          child: Row(
            children: [
              Btn('All Unrendered', kind: BtnKind.plain, small: true, onPressed: app.selectMissingScenes),
              const SizedBox(width: 8),
              Btn('Select All', kind: BtnKind.plain, small: true, onPressed: app.selectAllScenes),
              const SizedBox(width: 8),
              Btn('Clear', kind: BtnKind.plain, small: true, onPressed: app.clearSceneSelection),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            children: [
              Panel(
                child: Column(
                  children: [
                    for (final s in app.scenes) ...[_SceneRenderRow(scene: s), if (s != app.scenes.last) const Hairline()],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!app.isGenerating)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.rule)),
            ),
            child: Btn(
              'Render ${app.selectedScenes.length} Scenes',
              kind: BtnKind.primary,
              icon: Icons.graphic_eq_rounded,
              expand: true,
              onPressed: canRender ? app.renderSelectedScenes : null,
            ),
          ),
      ],
    );
  }
}

class _SceneRenderRow extends StatelessWidget {
  const _SceneRenderRow({required this.scene});
  final Scene scene;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final n = scene.number;
    final selected = app.selectedScenes.contains(n);
    final edited = app.scenesNeedingRerender.contains(n);
    final rendered = app.sceneFileInfo[n]?.exists == true;
    final rendering = app.isGenerating && app.renderingSceneNumbers.contains(n);
    final p = app.sceneProgress[n] ?? 0;
    return GestureDetector(
      onTap: () => app.toggleScene(n),
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: selected ? t.accentSoft.withValues(alpha: t.accentSoft.a * 0.6) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            CheckMark(checked: selected, onTap: () => app.toggleScene(n)),
            const SizedBox(width: 10),
            Text('Scene ${n.toString().padLeft(2, '0')}', style: TextStyles.script(t, size: 12, weight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(app.effectiveSceneTitle(scene), overflow: TextOverflow.ellipsis, style: TextStyles.ui(t, size: 12.5)),
            ),
            if (rendering && p < 1)
              SizedBox(
                width: 40,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: p, minHeight: 3, color: t.accent, backgroundColor: t.ctrl),
                ),
              )
            else if (edited)
              const Stamp('EDITED', kind: StampKind.warn)
            else if (rendered)
              const Stamp('RENDERED', kind: StampKind.ok),
          ],
        ),
      ),
    );
  }
}

/// While rendering: the "recording booth" card.
class _Booth extends StatelessWidget {
  const _Booth({required this.showLog, required this.onToggleLog});
  final bool showLog;
  final VoidCallback onToggleLog;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.booth, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _RecLamp(on: !app.isPaused),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: app.generationProgress == 0 ? null : app.generationProgress,
                    minHeight: 5,
                    color: t.highlighter,
                    backgroundColor: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            app.latestRenderLine,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyles.script(t, size: 11.5, color: t.boothSub),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _BoothButton(
                  app.isPaused ? 'Resume' : 'Pause',
                  icon: app.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  onTap: app.togglePause,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _BoothButton('Cancel', icon: Icons.close_rounded, danger: true, onTap: app.cancelGeneration),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onToggleLog,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  Icon(showLog ? Icons.expand_more_rounded : Icons.chevron_right_rounded, size: 16, color: t.boothSub),
                  Text(
                    'Show Log',
                    style: TextStyles.ui(t, size: 12, weight: FontWeight.w600, color: t.boothSub),
                  ),
                ],
              ),
            ),
          ),
          if (showLog)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                reverse: true,
                shrinkWrap: true,
                children: [
                  for (final l in app.generationLog.reversed)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${l.timestampString}  ${l.text}',
                        style: TextStyles.script(t, size: 10.5, color: l.style == LogStyle.error ? const Color(0xFFFF8F7E) : t.boothSub),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BoothButton extends StatelessWidget {
  const _BoothButton(this.label, {required this.icon, required this.onTap, this.danger = false});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final fg = danger ? const Color(0xFFFF9A8F) : t.boothInk;
    return Hover(
      cursor: SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 28,
          decoration: BoxDecoration(
            color: danger ? Colors.transparent : Colors.white.withValues(alpha: h ? 0.2 : 0.12),
            borderRadius: BorderRadius.circular(7),
            border: danger ? Border.all(color: const Color(0x99FF7A6E)) : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecLamp extends StatefulWidget {
  const _RecLamp({required this.on});
  final bool on;
  @override
  State<_RecLamp> createState() => _RecLampState();
}

class _RecLampState extends State<_RecLamp> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final reduce = MediaQuery.of(context).disableAnimations;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final glow = !widget.on ? 0.0 : (reduce ? 0.6 : 0.4 + 0.6 * c.value);
        return Tooltip(
          message: widget.on ? 'Recording' : 'Paused',
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: widget.on ? t.rec : t.boothSub,
              shape: BoxShape.circle,
              boxShadow: widget.on
                  ? [
                      BoxShadow(
                        color: t.rec.withValues(alpha: 0.7 * glow),
                        blurRadius: 10 * glow + 2,
                        spreadRadius: 2 * glow,
                      ),
                    ]
                  : null,
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Rehearse
// ---------------------------------------------------------------------------

class RehearseTab extends StatefulWidget {
  const RehearseTab({super.key});
  @override
  State<RehearseTab> createState() => _RehearseTabState();
}

class _RehearseTabState extends State<RehearseTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = context.read<AppState>();
      app.checkRenderedScenes();
      context.read<RehearsalPlayer>().load(app);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final p = context.watch<RehearsalPlayer>();
    if (p.scenes.isEmpty) {
      return const EmptyState(
        compact: true,
        art: EmptyArt.stage,
        title: 'No rendered scenes',
        message: 'Render at least one scene to use the rehearsal player.',
      );
    }
    final roles = (app.script?.characters.map((c) => c.name).toList() ?? <String>[])..sort();
    final cur = p.currentScene;
    final cue = p.currentCue;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
      children: [
        _groupLabel(t, 'Scene'),
        SelectField<int>(
          label: cur == null ? '' : 'Scene ${cur.sceneNumber}: ${cur.sceneTitle}',
          items: [
            for (var i = 0; i < p.scenes.length; i++)
              MenuItemSpec(i, 'Scene ${p.scenes[i].sceneNumber}: ${p.scenes[i].sceneTitle}', checked: i == p.currentSceneIndex),
          ],
          onSelected: (i) => p.switchToScene(i),
        ),
        const SizedBox(height: 12),
        // The stage: transport around a big yellow play button.
        Container(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.border),
            gradient: RadialGradient(
              center: const Alignment(0, -1.2),
              radius: 1.4,
              colors: t.dark ? [const Color(0xFF2B2A26), t.sheet] : [const Color(0xFFFFFDF0), t.sheet],
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Transport(Icons.skip_previous_rounded, 'Previous scene', p.currentSceneIndex > 0 ? p.prevScene : null),
                  const SizedBox(width: 10),
                  _Transport(Icons.fast_rewind_rounded, 'Previous line', p.prevLine),
                  const SizedBox(width: 14),
                  _PlayButton(playing: p.isPlaying, onTap: p.togglePlayPause),
                  const SizedBox(width: 14),
                  _Transport(Icons.fast_forward_rounded, 'Next line', p.nextLine),
                  const SizedBox(width: 10),
                  _Transport(Icons.skip_next_rounded, 'Next scene', p.currentSceneIndex < p.scenes.length - 1 ? p.nextScene : null),
                ],
              ),
              if (cue != null) ...[
                const SizedBox(height: 14),
                Text(
                  cue.speaker == narratorKey ? 'NARRATOR' : cue.speaker.toUpperCase(),
                  style: TextStyles.script(t, size: 10.5, weight: FontWeight.w700, color: t.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  p.blockMyLines && p.isMyLine(cue.speaker) ? blockText(cue.text) : cue.text,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyles.script(t, size: 12, color: t.ink2).copyWith(backgroundColor: p.isMyLine(cue.speaker) ? t.mine : null),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    Text('My Role', style: TextStyles.ui(t, weight: FontWeight.w600)),
                    const Spacer(),
                    SelectField<String>(
                      compact: true,
                      label: p.myRole.isEmpty ? 'Spectator' : titleCaseName(p.myRole),
                      leading: p.myRole.isEmpty ? null : SpeakerDot(p.myRole, allSpeakers: app.allSpeakers),
                      items: [
                        MenuItemSpec('', 'Spectator', checked: p.myRole.isEmpty),
                        const MenuItemSpec.divider(),
                        for (final r in roles) MenuItemSpec(r, titleCaseName(r), checked: r == p.myRole),
                      ],
                      onSelected: p.setRole,
                    ),
                  ],
                ),
              ),
              const Hairline(),
              _toggleRow(
                t,
                'Mute My Lines',
                p.muteMyLines,
                p.myRole.isEmpty ? null : p.setMute,
                p.myRole.isEmpty ? 'Select a role above to enable this' : 'Skip audio playback for your lines',
              ),
              const Hairline(),
              _toggleRow(
                t,
                'Block My Lines',
                p.blockMyLines,
                p.myRole.isEmpty ? null : p.setBlock,
                p.myRole.isEmpty ? 'Select a role above to enable this' : 'Replace your lines with underscores for memorization practice',
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            children: [
              Row(
                children: [
                  Text('Speed', style: TextStyles.ui(t, weight: FontWeight.w600)),
                  const Spacer(),
                  Text(
                    '${p.playbackRate.toStringAsFixed(2)}×',
                    style: TextStyles.script(t, size: 12, weight: FontWeight.w700, color: t.ink2),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _RoundStep('−', 'Slower (−0.05×)', p.playbackRate <= 0.5 ? null : () => p.stepRate(-0.05)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        activeTrackColor: t.accent,
                        inactiveTrackColor: t.ctrl,
                        thumbColor: t.knob,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 2),
                      ),
                      child: Slider(value: p.playbackRate, min: 0.5, max: 2.0, onChanged: p.setRate),
                    ),
                  ),
                  _RoundStep('+', 'Faster (+0.05×)', p.playbackRate >= 2.0 ? null : () => p.stepRate(0.05)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toggleRow(Tokens t, String label, bool value, ValueChanged<bool>? onChanged, String help) => Tooltip(
    message: help,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Row(
        children: [
          Text(label, style: TextStyles.ui(t, color: onChanged == null ? t.faint : t.ink)),
          const Spacer(),
          Toggle(value: value, onChanged: onChanged),
        ],
      ),
    ),
  );
}

class _Transport extends StatelessWidget {
  const _Transport(this.icon, this.help, this.onTap);
  final IconData icon;
  final String help;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: help,
      child: Hover(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: h && onTap != null ? t.accentSoft : t.ctrl, shape: BoxShape.circle),
            child: Icon(icon, size: 18, color: onTap == null ? t.faint : t.ink2),
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Hover(
        cursor: SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: onTap,
          child: AnimatedScale(
            scale: h ? 1.04 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: t.highlighter,
                shape: BoxShape.circle,
                border: Border.all(color: t.highlighterEdge, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFB8AE1E).withValues(alpha: t.dark ? 0.35 : 0.45),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: const Color(0xFF1C1B19)),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundStep extends StatelessWidget {
  const _RoundStep(this.label, this.help, this.onTap);
  final String label;
  final String help;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Tooltip(
      message: help,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: t.border),
            ),
            child: Text(
              label,
              style: TextStyles.ui(t, weight: FontWeight.w700, color: onTap == null ? t.faint : t.ink2),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

class LogTab extends StatefulWidget {
  const LogTab({super.key});
  @override
  State<LogTab> createState() => _LogTabState();
}

class _LogTabState extends State<LogTab> {
  LogStyle? filter;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final app = context.watch<AppState>();
    final entries = filter == null ? app.debugLog : app.debugLog.where((e) => e.style == filter).toList();
    Widget chip(String label, LogStyle? f) => GestureDetector(
      onTap: () => setState(() => filter = filter == f ? null : f),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: filter == f ? t.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(5)),
          child: Text(
            label,
            style: TextStyles.ui(t, size: 11.5, weight: filter == f ? FontWeight.w700 : FontWeight.w500, color: filter == f ? t.accent : t.muted),
          ),
        ),
      ),
    );
    Color color(LogStyle s) => switch (s) {
      LogStyle.error => t.danger,
      LogStyle.warning => t.warn,
      LogStyle.success => t.ok,
      LogStyle.info => t.ink,
      LogStyle.debug => t.muted,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 6),
          child: Row(
            children: [
              Text('${app.debugLog.length} entries', style: TextStyles.ui(t, size: 12, color: t.muted)),
              const Spacer(),
              chip('All', null),
              chip('Err', LogStyle.error),
              chip('Warn', LogStyle.warning),
              chip('Py', LogStyle.debug),
              IconBtn(
                Icons.copy_rounded,
                size: 14,
                tooltip: 'Copy all log entries',
                onTap: () => copyText(app.debugLog.map((e) => '[${e.timestampString}] ${e.text}').join('\n')),
              ),
              IconBtn(Icons.delete_outline_rounded, size: 15, tooltip: 'Clear log', onTap: app.clearDebugLog),
            ],
          ),
        ),
        Expanded(
          child: app.debugLog.isEmpty
              ? const EmptyState(compact: true, art: EmptyArt.promptBook, title: 'No activity yet')
              : Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  decoration: BoxDecoration(
                    color: t.sheet,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: t.border),
                  ),
                  child: ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[entries.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 62,
                              child: Text(e.timestampString, style: TextStyles.script(t, size: 10, color: t.faint)),
                            ),
                            Expanded(
                              child: SelectableText(e.text, style: TextStyles.script(t, size: 10.5, color: color(e.style))),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// Opened from Cast when an engine isn't installed.
void openEnginesSettings(BuildContext context) => showSettingsSheet(context, initialTab: 1);
