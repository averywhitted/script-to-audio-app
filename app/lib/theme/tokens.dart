// Design tokens: Claude Design "Table Read 1a v2" restyled with the app icon's
// colors ("blue leads", decided 2026-10-07). Every color the UI uses comes from
// here. Contrast pairs were checked to WCAG AA (4.5:1) for text.

import 'dart:math' as math;

import 'package:flutter/material.dart';

class Tokens {
  const Tokens({
    required this.dark,
    required this.bg,
    required this.sheet,
    required this.panel,
    required this.ctrl,
    required this.ctrlOn,
    required this.field,
    required this.border,
    required this.rule,
    required this.ruleSoft,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.accentLine,
    required this.highlighter,
    required this.mine,
    required this.highlighterEdge,
    required this.ok,
    required this.okSoft,
    required this.okDot,
    required this.warn,
    required this.warnSoft,
    required this.danger,
    required this.dangerSoft,
    required this.rec,
    required this.bar,
    required this.barInk,
    required this.barBtn,
    required this.barBtnOn,
    required this.barDangerInk,
    required this.booth,
    required this.boothInk,
    required this.boothSub,
    required this.knob,
    required this.shadow,
    required this.hlLightness,
    required this.hlChroma,
    required this.hlAlpha,
    required this.dotLightness,
    required this.nameInk,
  });

  final bool dark;
  final Color bg, sheet, panel, ctrl, ctrlOn, field, border, rule, ruleSoft;
  final Color ink, ink2, muted, faint;
  final Color accent, onAccent, accentSoft, accentLine;
  final Color highlighter, mine, highlighterEdge;
  final Color ok, okSoft, okDot, warn, warnSoft, danger, dangerSoft, rec;
  final Color bar, barInk, barBtn, barBtnOn, barDangerInk;
  final Color booth, boothInk, boothSub, knob;
  final List<BoxShadow> shadow;
  final double hlLightness, hlChroma, hlAlpha, dotLightness;
  final Color nameInk;

  static const light = Tokens(
    dark: false,
    bg: Color(0xFFF7F6F3),
    sheet: Color(0xFFFFFFFF),
    panel: Color(0xFFF0EFEB),
    ctrl: Color(0xFFE8E6E1),
    ctrlOn: Color(0xFFFFFFFF),
    field: Color(0xFFFFFFFF),
    border: Color(0xFFDAD7D0),
    rule: Color(0x1A1C1B19),
    ruleSoft: Color(0x0D1C1B19),
    ink: Color(0xFF1C1B19),
    ink2: Color(0xFF46433E),
    muted: Color(0xFF6B6760),
    faint: Color(0xFF8E897F),
    accent: Color(0xFF2C6BC9),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x172C6BC9),
    accentLine: Color(0x992C6BC9),
    highlighter: Color(0xFFFFFB85),
    mine: Color(0xE6FFFB85),
    highlighterEdge: Color(0xCC1C1B19),
    ok: Color(0xFF2E7350),
    okSoft: Color(0x29499167),
    okDot: Color(0xFF499167),
    warn: Color(0xFFB4560E),
    warnSoft: Color(0x26E08228),
    danger: Color(0xFFC4302B),
    dangerSoft: Color(0x17C4302B),
    rec: Color(0xFFE5483B),
    bar: Color(0xFF1C1B19),
    barInk: Color(0xFFF7F6F3),
    barBtn: Color(0x1CFFFFFF),
    barBtnOn: Color(0x38FFFFFF),
    barDangerInk: Color(0xFFFF9A8F),
    booth: Color(0xFFFFFFFF),
    boothInk: Color(0xFF1F1E1C),
    boothSub: Color(0xFF6F6A62),
    knob: Color(0xFFFFFFFF),
    shadow: [BoxShadow(color: Color(0x1F14140F), blurRadius: 18, offset: Offset(0, 8))],
    hlLightness: 0.88,
    hlChroma: 0.12,
    hlAlpha: 0.72,
    dotLightness: 0.64,
    nameInk: Color(0xFF1C1B19),
  );

  static const darkTokens = Tokens(
    dark: true,
    bg: Color(0xFF161615),
    sheet: Color(0xFF1F1F1D),
    panel: Color(0xFF1A1A18),
    ctrl: Color(0x14FFFFFF),
    ctrlOn: Color(0xFF3A3936),
    field: Color(0xFF141413),
    border: Color(0xFF34332F),
    rule: Color(0x14FFFFFF),
    ruleSoft: Color(0x0BFFFFFF),
    ink: Color(0xFFEFEDE8),
    ink2: Color(0xFFCFCCC5),
    muted: Color(0xFF9C978E),
    faint: Color(0xFF7D786F),
    accent: Color(0xFF7AABF2),
    onAccent: Color(0xFF0F1B2E),
    accentSoft: Color(0x1F7AABF2),
    accentLine: Color(0x997AABF2),
    highlighter: Color(0xFFFFFB85),
    mine: Color(0x38FFFB85),
    highlighterEdge: Color(0x00000000),
    ok: Color(0xFF6CC08E),
    okSoft: Color(0x296CC08E),
    okDot: Color(0xFF6CC08E),
    warn: Color(0xFFF0A050),
    warnSoft: Color(0x29F0A050),
    danger: Color(0xFFFF7A6E),
    dangerSoft: Color(0x21FF7A6E),
    rec: Color(0xFFFF5A4A),
    bar: Color(0xFFEFEDE8),
    barInk: Color(0xFF161615),
    barBtn: Color(0x14000000),
    barBtnOn: Color(0x29000000),
    barDangerInk: Color(0xFFB3261E),
    booth: Color(0xFF0E0E0D),
    boothInk: Color(0xFFEFEDE8),
    boothSub: Color(0xFFA8A399),
    knob: Color(0xFFEFEDE8),
    shadow: [BoxShadow(color: Color(0x73000000), blurRadius: 22, offset: Offset(0, 10))],
    hlLightness: 0.72,
    hlChroma: 0.13,
    hlAlpha: 0.32,
    dotLightness: 0.76,
    nameInk: Color(0xFFEFEDE8),
  );

  static Tokens of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? darkTokens : light;
}

/// Font families bundled in assets/fonts (all SIL OFL).
class Fonts {
  static const ui = 'Hanken';
  static const script = 'CourierPrime';
  static const hand = 'Caveat';
  static const display = 'YoungSerif';
}

/// Type scale (Mac-sized: 13 pt body).
class TextStyles {
  static TextStyle ui(Tokens t, {double size = 13, FontWeight weight = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(fontFamily: Fonts.ui, fontSize: size, fontWeight: weight, color: color ?? t.ink, height: height ?? 1.35);

  static TextStyle script(Tokens t, {double size = 13, FontWeight weight = FontWeight.w400, Color? color, bool italic = false}) => TextStyle(
    fontFamily: Fonts.script,
    fontSize: size,
    fontWeight: weight,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    color: color ?? t.ink,
    height: 1.5,
  );

  static TextStyle display(Tokens t, {double size = 22, Color? color}) =>
      TextStyle(fontFamily: Fonts.display, fontSize: size, color: color ?? t.ink, height: 1.15);

  static TextStyle hand(Tokens t, {double size = 19, Color? color}) =>
      TextStyle(fontFamily: Fonts.hand, fontWeight: FontWeight.w600, fontSize: size, color: color ?? t.muted, height: 1);

  static TextStyle label(Tokens t) => TextStyle(fontFamily: Fonts.ui, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: t.muted);
}

// ---------------------------------------------------------------------------
// Character highlighter colors (OKLCH, hand-picked hues; no yellow, no azure)
// ---------------------------------------------------------------------------

/// Hues chosen to stay clear of the brand yellow (~85-115) and the action blue (~240-265).
const _hues = <double>[320, 195, 150, 355, 45, 290, 170, 25, 130, 335, 210, 60];

class SpeakerColors {
  const SpeakerColors({required this.highlight, required this.dot, required this.nameInk});
  final Color highlight;
  final Color dot;
  final Color nameInk;
}

/// One consistent color per character, used on every screen.
/// `allSpeakers` is the script's character list; Narrator is always neutral.
/// Settings → General → "Character highlight colors". When off, every name
/// uses the neutral narrator tag. Set by AppState; [enabled] overrides it for previews.
bool characterColorsEnabled = true;

SpeakerColors speakerColors(String speaker, List<String> allSpeakers, Tokens t, {bool? enabled}) {
  final isNarrator = speaker.isEmpty || speaker == 'Narrator' || speaker == 'NARRATOR' || speaker == '__NARRATOR__';
  if (isNarrator || !(enabled ?? characterColorsEnabled)) {
    return SpeakerColors(highlight: oklch(t.hlLightness, 0.01, 70, t.hlAlpha), dot: oklch(t.dotLightness, 0.01, 70), nameInk: t.nameInk);
  }
  final sorted = allSpeakers.where((s) => s != 'Narrator').toList()..sort();
  var idx = sorted.indexOf(speaker);
  if (idx < 0) {
    final lower = speaker.toLowerCase();
    idx = sorted.indexWhere((s) => s.toLowerCase() == lower);
  }
  double hue;
  if (idx >= 0 && idx < _hues.length) {
    hue = _hues[idx];
  } else {
    // Past 12 characters (or unknown names): spread by golden angle, skipping
    // the yellow and azure bands so no character looks like the accent.
    final seed = idx >= 0 ? idx : _djb2(speaker);
    hue = (seed * 137.508) % 360;
    if (hue > 80 && hue < 118) hue = (hue + 40) % 360;
    if (hue > 235 && hue < 270) hue = (hue + 40) % 360;
  }
  return SpeakerColors(highlight: oklch(t.hlLightness, t.hlChroma, hue, t.hlAlpha), dot: oklch(t.dotLightness, 0.15, hue), nameInk: t.nameInk);
}

int _djb2(String s) {
  var h = 5381;
  for (final c in s.codeUnits) {
    h = ((h << 5) + h + c) & 0x7fffffff;
  }
  return h;
}

/// OKLCH → sRGB, clamped to the gamut.
Color oklch(double l, double c, double hDeg, [double alpha = 1]) {
  final h = hDeg * math.pi / 180;
  final a = c * math.cos(h);
  final b = c * math.sin(h);
  final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
  final l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_;
  final r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
  final g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  final bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;
  int ch(double x) {
    final v = x <= 0.0031308 ? 12.92 * x : 1.055 * math.pow(x, 1 / 2.4) - 0.055;
    return (v.clamp(0.0, 1.0) * 255).round();
  }

  return Color.fromARGB((alpha * 255).round(), ch(r), ch(g), ch(bl));
}

ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.dark ? Tokens.darkTokens : Tokens.light;
  return ThemeData(
    brightness: brightness,
    useMaterial3: true,
    fontFamily: Fonts.ui,
    scaffoldBackgroundColor: t.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: brightness,
      primary: t.accent,
      onPrimary: t.onAccent,
      surface: t.sheet,
      onSurface: t.ink,
      error: t.danger,
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: t.accent, selectionColor: t.accentSoft),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: t.bar, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(fontFamily: Fonts.ui, fontSize: 11.5, color: t.barInk),
      waitDuration: const Duration(milliseconds: 450),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(t.muted.withValues(alpha: 0.35)),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.dark ? const Color(0xFF2A2927) : Colors.white,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(fontFamily: Fonts.ui, fontSize: 13, color: t.ink),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: t.border),
      ),
      elevation: 8,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: t.ruleSoft,
  );
}
