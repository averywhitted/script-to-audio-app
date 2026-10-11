// Shared components for the 1a v2 design, styled from theme/tokens.dart.

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Rebuilds with whether the pointer is over [child].
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.cursor = MouseCursor.defer});
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _h = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    onEnter: (_) => setState(() => _h = true),
    onExit: (_) => setState(() => _h = false),
    child: widget.builder(context, _h),
  );
}

enum BtnKind { primary, secondary, danger, warn, plain, link }

/// Mac-sized button. Primary = action blue.
class Btn extends StatelessWidget {
  const Btn(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = BtnKind.secondary,
    this.icon,
    this.trailingIcon,
    this.expand = false,
    this.small = false,
    this.tooltip,
  });
  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool expand;
  final bool small;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final enabled = onPressed != null;
    final (Color bg, Color fg, Color? edge) = switch (kind) {
      BtnKind.primary => (t.accent, t.onAccent, null),
      BtnKind.secondary => (t.sheet, t.ink, t.border),
      BtnKind.danger => (t.dangerSoft, t.danger, null),
      BtnKind.warn => (t.warnSoft, t.warn, null),
      BtnKind.plain => (Colors.transparent, t.ink2, null),
      BtnKind.link => (Colors.transparent, t.accent, null),
    };
    Widget b = Hover(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      builder: (context, h) {
        final hoverTint = kind == BtnKind.primary ? Colors.black.withValues(alpha: h ? 0.08 : 0) : t.ink.withValues(alpha: h && enabled ? 0.05 : 0);
        return GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              height: small ? 24 : 30,
              padding: EdgeInsets.symmetric(horizontal: kind == BtnKind.link || kind == BtnKind.plain ? 4 : (small ? 10 : 14)),
              decoration: BoxDecoration(
                color: bg == Colors.transparent ? null : Color.alphaBlend(hoverTint, bg),
                borderRadius: BorderRadius.circular(7),
                border: edge == null ? null : Border.all(color: edge),
              ),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, size: small ? 13 : 15, color: fg), const SizedBox(width: 6)],
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyles.ui(
                        t,
                        size: small ? 12 : 13,
                        weight: kind == BtnKind.plain || kind == BtnKind.link ? FontWeight.w500 : FontWeight.w600,
                        color: (kind == BtnKind.plain && h && enabled) ? t.ink : fg,
                      ),
                    ),
                  ),
                  if (trailingIcon != null) ...[const SizedBox(width: 4), Icon(trailingIcon, size: small ? 12 : 14, color: fg)],
                ],
              ),
            ),
          ),
        );
      },
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return b;
  }
}

/// Small pill used for per-line actions (Edit, Remove, Restore, Add line…).
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.onTap, this.icon, this.bg, this.fg, this.tooltip});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? bg;
  final Color? fg;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget p = Hover(
      cursor: SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Color.alphaBlend(t.ink.withValues(alpha: h ? 0.06 : 0), bg ?? t.ctrl),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 11, color: fg ?? t.ink2), const SizedBox(width: 3)],
              Text(
                label,
                style: TextStyles.ui(t, size: 11, weight: FontWeight.w600, color: fg ?? t.ink2),
              ),
            ],
          ),
        ),
      ),
    );
    if (tooltip != null) p = Tooltip(message: tooltip!, child: p);
    return p;
  }
}

enum StampKind { ok, warn, neutral, accent }

/// Small caps status label (RENDERED, EDITED, ADDED, BETA).
class Stamp extends StatelessWidget {
  const Stamp(this.label, {super.key, this.kind = StampKind.neutral, this.icon, this.tilt = 0});
  final String label;
  final StampKind kind;
  final IconData? icon;
  final double tilt;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final (bg, fg) = switch (kind) {
      StampKind.ok => (t.okSoft, t.ok),
      StampKind.warn => (t.warnSoft, t.warn),
      StampKind.accent => (t.accentSoft, t.accent),
      StampKind.neutral => (t.ctrl, t.muted),
    };
    return Transform.rotate(
      angle: tilt,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 10, color: fg), const SizedBox(width: 3)],
            Text(
              label,
              style: TextStyle(fontFamily: Fonts.ui, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.7, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square checkbox (lines, scenes) or round one (projects).
class CheckMark extends StatelessWidget {
  const CheckMark({super.key, required this.checked, this.onTap, this.round = false, this.size = 14, this.tooltip});
  final bool checked;
  final VoidCallback? onTap;
  final bool round;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget c = GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: checked ? t.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(round ? size : 4),
            border: Border.all(color: checked ? t.accent : t.muted.withValues(alpha: 0.7), width: 1.5),
          ),
          child: checked ? Icon(Icons.check_rounded, size: size - 3, color: t.onAccent) : null,
        ),
      ),
    );
    if (tooltip != null) c = Tooltip(message: tooltip!, child: c);
    return c;
  }
}

/// Segmented control. [selected] is the index of the active segment.
class Segmented extends StatelessWidget {
  const Segmented({super.key, required this.labels, required this.selected, required this.onChanged, this.icons, this.small = false, this.width});
  final List<String> labels;
  final List<IconData>? icons;
  final int selected;
  final ValueChanged<int> onChanged;
  final bool small;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: t.ctrl, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: width == null ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (var i = 0; i < labels.length; i++)
            _wrap(
              GestureDetector(
                onTap: () => onChanged(i),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: small ? 20 : 24,
                    padding: EdgeInsets.symmetric(horizontal: small ? 8 : 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == selected ? t.ctrlOn : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: i == selected && !t.dark ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 2, offset: Offset(0, 1))] : null,
                    ),
                    child: icons != null && labels[i].isEmpty
                        ? Icon(icons![i], size: 15, color: i == selected ? t.ink : t.muted)
                        : Text(
                            labels[i],
                            style: TextStyles.ui(
                              t,
                              size: small ? 11 : 12.5,
                              weight: i == selected ? FontWeight.w600 : FontWeight.w500,
                              color: i == selected ? t.ink : t.muted,
                            ),
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrap(Widget w) => width == null ? w : Expanded(child: w);
}

/// On/off switch tinted with the action blue.
class Toggle extends StatelessWidget {
  const Toggle({super.key, required this.value, this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final enabled = onChanged != null;
    return GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 32,
            height: 19,
            padding: const EdgeInsets.all(2),
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
              color: value ? t.accent : t.ctrl,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: value ? Colors.transparent : t.border),
            ),
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: value ? Colors.white : t.knob,
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 2, offset: Offset(0, 1))],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MenuItemSpec<T> {
  const MenuItemSpec(this.value, this.label, {this.header = false, this.divider = false, this.checked = false, this.enabled = true});
  const MenuItemSpec.header(this.label) : value = null, header = true, divider = false, checked = false, enabled = false;
  const MenuItemSpec.divider() : value = null, label = '', header = false, divider = true, checked = false, enabled = false;
  final T? value;
  final String label;
  final bool header;
  final bool divider;
  final bool checked;
  final bool enabled;
}

/// Opens a menu anchored under [anchorContext].
Future<T?> showAnchoredMenu<T>(BuildContext anchorContext, List<MenuItemSpec<T>> items) {
  final t = Tokens.of(anchorContext);
  final box = anchorContext.findRenderObject() as RenderBox;
  final overlay = Overlay.of(anchorContext).context.findRenderObject() as RenderBox;
  final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
  final rect = RelativeRect.fromLTRB(topLeft.dx, topLeft.dy, overlay.size.width - topLeft.dx - box.size.width, 0);
  return showMenu<T>(
    context: anchorContext,
    position: rect,
    constraints: BoxConstraints(minWidth: box.size.width.clamp(140, 360), maxWidth: 380),
    items: [
      for (final it in items)
        if (it.divider)
          const PopupMenuDivider(height: 9)
        else if (it.header)
          PopupMenuItem<T>(enabled: false, height: 24, child: Text(it.label.toUpperCase(), style: TextStyles.label(t)))
        else
          PopupMenuItem<T>(
            value: it.value,
            enabled: it.enabled,
            height: 30,
            child: Row(
              children: [
                SizedBox(width: 18, child: it.checked ? Icon(Icons.check_rounded, size: 14, color: t.accent) : null),
                Expanded(
                  child: Text(
                    it.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.ui(t, color: it.enabled ? t.ink : t.faint),
                  ),
                ),
              ],
            ),
          ),
    ],
  );
}

/// A field-looking button that opens a menu (Mac pop-up button).
class SelectField<T> extends StatelessWidget {
  const SelectField({
    super.key,
    required this.label,
    required this.items,
    required this.onSelected,
    this.leading,
    this.compact = false,
    this.placeholder = false,
  });
  final String label;
  final List<MenuItemSpec<T>> items;
  final ValueChanged<T> onSelected;
  final Widget? leading;
  final bool compact;
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Builder(
      builder: (ctx) => Hover(
        cursor: SystemMouseCursors.click,
        builder: (context, h) => GestureDetector(
          onTap: () async {
            final v = await showAnchoredMenu<T>(ctx, items);
            if (v != null) onSelected(v);
          },
          child: Container(
            height: compact ? 26 : 30,
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
            decoration: BoxDecoration(
              color: compact ? (h ? t.ctrl : Colors.transparent) : t.field,
              borderRadius: BorderRadius.circular(7),
              border: compact ? null : Border.all(color: h ? t.muted.withValues(alpha: 0.5) : t.border),
            ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 6)],
                Flexible(
                  fit: compact ? FlexFit.loose : FlexFit.tight,
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyles.ui(t, color: placeholder ? t.muted : t.ink),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.unfold_more_rounded, size: 14, color: t.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dark floating pill (selection bars, undo/redo).
class FloatingBar extends StatelessWidget {
  const FloatingBar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: t.bar,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class BarButton extends StatelessWidget {
  const BarButton(this.label, {super.key, this.onTap, this.danger = false, this.active = false, this.icon, this.enabled = true, this.tooltip});
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool active;
  final IconData? icon;
  final bool enabled;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget b = Hover(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      builder: (context, h) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(color: active || (h && enabled) ? t.barBtnOn : t.barBtn, borderRadius: BorderRadius.circular(8)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 14, color: danger ? t.barDangerInk : t.barInk), if (label.isNotEmpty) const SizedBox(width: 5)],
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: TextStyles.ui(t, size: 12.5, weight: FontWeight.w600, color: danger ? t.barDangerInk : t.barInk),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return b;
  }
}

class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, this.onTap, this.tooltip, this.size = 16, this.color, this.box = 28});
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final Color? color;
  final double box;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    Widget b = Hover(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      builder: (context, h) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: box,
          height: box,
          decoration: BoxDecoration(color: h && onTap != null ? t.ctrl : Colors.transparent, borderRadius: BorderRadius.circular(7)),
          child: Icon(icon, size: size, color: onTap == null ? t.faint : (color ?? t.muted)),
        ),
      ),
    );
    if (tooltip != null) b = Tooltip(message: tooltip!, child: b);
    return b;
  }
}

/// Character name with its highlighter stroke.
class NameChip extends StatelessWidget {
  const NameChip(this.name, {super.key, required this.allSpeakers, this.uppercase = false, this.size = 10.5, this.strike = false, this.colors});
  final String name;
  final List<String> allSpeakers;
  final bool uppercase;
  final double size;
  final bool strike;

  /// Overrides the "Character highlight colors" setting (used by its preview).
  final bool? colors;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final c = speakerColors(name, allSpeakers, t, enabled: colors);
    final shown = uppercase ? name.toUpperCase() : _title(name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: c.highlight, borderRadius: BorderRadius.circular(3)),
      child: Text(
        shown,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: Fonts.script,
          fontWeight: FontWeight.w700,
          fontSize: size,
          color: c.nameInk,
          decoration: strike ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }

  static String _title(String s) {
    if (s == '__NARRATOR__') return 'Narrator';
    return s.split(' ').map((w) => w.isEmpty ? w : (w == w.toUpperCase() && w.length > 1 ? w[0] + w.substring(1).toLowerCase() : w)).join(' ');
  }
}

String titleCaseName(String s) => NameChip._title(s);

class SpeakerDot extends StatelessWidget {
  const SpeakerDot(this.name, {super.key, required this.allSpeakers, this.size = 8});
  final String name;
  final List<String> allSpeakers;
  final double size;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: speakerColors(name, allSpeakers, t).dot, shape: BoxShape.circle),
    );
  }
}

/// A card with the sheet background and a hairline border.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = EdgeInsets.zero, this.radius = 10});
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: t.border),
      ),
      child: child,
    );
  }
}

/// Text input styled like the design's fields.
class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.controller,
    this.placeholder,
    this.obscure = false,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.onSubmitted,
    this.mono = false,
    this.onChanged,
    this.focusNode,
  });
  final TextEditingController controller;
  final String? placeholder;
  final bool obscure;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool mono;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final style = mono ? TextStyles.script(t) : TextStyles.ui(t);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscure,
      maxLines: obscure ? 1 : maxLines,
      minLines: minLines,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: style,
      cursorColor: t.accent,
      decoration: InputDecoration(
        isDense: true,
        hintText: placeholder,
        hintStyle: style.copyWith(color: t.faint),
        filled: true,
        fillColor: t.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Popovers and sheets (single window: everything opens inside it)
// ---------------------------------------------------------------------------

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({required this.anchor, required this.builder, required this.width});
  final Rect anchor;
  final WidgetBuilder builder;
  final double width;

  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final t = Tokens.of(context);
    final size = MediaQuery.of(context).size;
    final left = (anchor.center.dx - width / 2).clamp(12.0, size.width - width - 12);
    final below = anchor.bottom + 8;
    final openUp = below > size.height - 260;
    return Stack(
      children: [
        Positioned(
          left: left,
          top: openUp ? null : below,
          bottom: openUp ? size.height - anchor.top + 8 : null,
          width: width,
          child: FadeTransition(
            opacity: animation,
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: t.dark ? const Color(0xFF2A2927) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: t.border),
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 10))],
                ),
                child: Builder(builder: builder),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<T?> showPopover<T>(BuildContext anchorContext, WidgetBuilder builder, {double width = 320}) {
  final box = anchorContext.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return Navigator.of(anchorContext).push(_PopoverRoute<T>(anchor: rect, builder: builder, width: width));
}

/// Mac-style sheet: slides down from the top of the window over a dimmed backdrop.
Future<T?> showSheet<T>(BuildContext context, WidgetBuilder builder, {double width = 480, bool dismissible = true}) {
  final t = Tokens.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: t.dark ? 0.45 : 0.22),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, a, b) => Align(
      alignment: const Alignment(0, -0.35),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: width,
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height - 80),
          decoration: BoxDecoration(
            color: t.dark ? const Color(0xFF242422) : t.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.border),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 18))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Builder(builder: builder),
        ),
      ),
    ),
    transitionBuilder: (ctx, a, b, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, -0.04), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

/// In-window confirmation (replaces macOS confirmation dialogs).
Future<String?> showConfirm(BuildContext context, {required String title, String? message, required List<(String, BtnKind)> buttons}) {
  final t = Tokens.of(context);
  return showSheet<String>(
    context,
    (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyles.ui(t, size: 15, weight: FontWeight.w700)),
          if (message != null) ...[const SizedBox(height: 8), Text(message, style: TextStyles.ui(t, color: t.ink2, height: 1.45))],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              for (final (label, kind) in buttons) ...[const SizedBox(width: 8), Btn(label, kind: kind, onPressed: () => Navigator.of(ctx).pop(label))],
            ],
          ),
        ],
      ),
    ),
    width: 420,
  );
}

/// Copies text, ignoring failures.
Future<void> copyText(String s) async {
  try {
    await Clipboard.setData(ClipboardData(text: s));
  } catch (_) {}
}

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.icon, required this.title, this.subtitle, this.iconColor});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
      child: Column(
        children: [
          Icon(icon, size: 36, color: iconColor ?? t.accent),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: TextStyles.display(t, size: 22)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyles.ui(t, color: t.ink2, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }
}

class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false});
  final bool vertical;
  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    return vertical ? Container(width: 1, color: t.rule) : Container(height: 1, color: t.rule);
  }
}

/// Mac-style clicks: [onClick] fires on mouse-down (no double-tap delay),
/// [onDoubleClick] on a second click within 400 ms. A nested ClickTarget that
/// handles a double-click stops outer ones from also handling it.
class ClickTarget extends StatefulWidget {
  const ClickTarget({super.key, required this.child, this.onClick, this.onDoubleClick});

  /// Timestamp of the last mouse-down any ClickTarget received, so an
  /// enclosing background can tell its click landed on empty space.
  static Duration? lastHandledDown;
  final Widget child;
  final VoidCallback? onClick;
  final VoidCallback? onDoubleClick;
  @override
  State<ClickTarget> createState() => _ClickTargetState();
}

class _ClickTargetState extends State<ClickTarget> {
  static Duration? _consumedAt;
  Duration? _lastDown;
  Offset? _lastPos;
  bool _armed = false;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (e) {
      if (e.buttons != kPrimaryMouseButton) return;
      ClickTarget.lastHandledDown = e.timeStamp;
      final isDouble = _lastDown != null && e.timeStamp - _lastDown! < const Duration(milliseconds: 400) && (_lastPos! - e.position).distance < 6;
      if (isDouble) {
        _lastDown = null;
        if (_consumedAt == e.timeStamp) return;
        // Only act if double-click was available when the first click
        // landed (e.g. rename only a card that was already selected).
        if (widget.onDoubleClick != null && _armed) {
          _consumedAt = e.timeStamp;
          widget.onDoubleClick!();
        }
      } else {
        _lastDown = e.timeStamp;
        _lastPos = e.position;
        _armed = widget.onDoubleClick != null;
        if (_consumedAt == e.timeStamp) return;
        widget.onClick?.call();
      }
    },
    child: widget.child,
  );
}
