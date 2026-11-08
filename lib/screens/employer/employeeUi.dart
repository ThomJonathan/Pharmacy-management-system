import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ============================================================================
// EMPLOYEE UI — Shared tokens and minimal UI primitives for branch staff.
// Adheres strictly to minimal, professional design:
//   - No excessive shadows, no glowing borders, no colour gradients.
//   - Restrained border radius (4px standard, 3px pills, 6px modal sheets).
//   - Hierarchy established via typography, spacing, contrast, dividers, layout.
//   - Zero generic filler/vanity metrics or meaningless UI noise.
// ============================================================================

const double empWideBreakpoint = 760;
const double empTabletBreakpoint = 600;

const Color empBg = Color(0xFFF7F9FF);
const Color empSurface = Colors.white;
const Color empBorder = Color(0xFFD9E2F5);
const Color empInk = Color(0xFF0F2038);
const Color empMuted = Color(0xFF5B6B8C);
const Color empPrimary = Color(0xFF143D9E);
const Color empPrimaryTint = Color(0xFFE4EAFB);
const Color empGold = Color(0xFFC9A227);
const Color empWarn = Color(0xFFB07A28);
const Color empWarnTint = Color(0xFFFEF6E8);
const Color empDanger = Color(0xFFB4544A);
const Color empDangerTint = Color(0xFFFBEBEA);
const Color empSuccess = Color(0xFF2E7D32);
const Color empSuccessTint = Color(0xFFE8F5E9);

TextStyle empSans(
  double size, {
  FontWeight? weight,
  Color? color,
  double? height,
  double? letterSpacing,
}) =>
    GoogleFonts.ibmPlexSans(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );

TextStyle empMono(
  double size, {
  FontWeight? weight,
  Color? color,
  double? height,
  double? letterSpacing,
}) =>
    GoogleFonts.ibmPlexMono(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );

String empMk(double amount) {
  final neg = amount < 0;
  final s = amount.abs().round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return 'MK ${neg ? '-' : ''}$buf';
}

String empQty(double q) =>
    q.toStringAsFixed(q.truncateToDouble() == q ? 0 : 2);

void empToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: empSans(13, weight: FontWeight.w500, color: Colors.white),
      ),
      backgroundColor: error ? empDanger : empPrimary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// Single border/background container for structured grouping without shadows.
class EmpCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Border? border;

  const EmpCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? empSurface,
        border: border ?? Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }
}

/// Clean empty state with restrained icon, title, description, and optional action.
class EmpEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? title;
  final Widget? action;

  const EmpEmpty({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: empMuted),
            const SizedBox(height: 10),
            if (title != null) ...[
              Text(
                title!,
                style: empSans(14, weight: FontWeight.w600, color: empInk),
              ),
              const SizedBox(height: 4),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: empSans(12.5, color: empMuted, height: 1.4),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Clean metric unit using typography scale, weight, and subtle colors instead of box cards.
class EmpStatMetric extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? valueColor;
  final bool mono;

  const EmpStatMetric({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.valueColor,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: empSans(12, color: empMuted)),
        const SizedBox(height: 4),
        Text(
          value,
          style: mono
              ? empMono(20, weight: FontWeight.w700, color: valueColor ?? empInk)
              : empSans(20, weight: FontWeight.w700, color: valueColor ?? empInk),
        ),
        if (sub != null) ...[
          const SizedBox(height: 2),
          Text(sub!, style: empSans(11.5, color: empMuted)),
        ],
      ],
    );
  }
}

/// Section title with optional action, establishing hierarchy with typography and whitespace.
class EmpSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? action;

  const EmpSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: empSans(14, weight: FontWeight.w700, color: empInk),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: empSans(12, color: empMuted)),
              ],
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

/// Compact status indicator badge with 3px radius.
class EmpStatusPill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;

  const EmpStatusPill({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });

  factory EmpStatusPill.active([String label = 'Active']) => EmpStatusPill(
        label: label,
        bg: empSuccessTint,
        fg: empSuccess,
        icon: Icons.check_circle_outline,
      );

  factory EmpStatusPill.warning(String label, {IconData? icon}) => EmpStatusPill(
        label: label,
        bg: empWarnTint,
        fg: empWarn,
        icon: icon,
      );

  factory EmpStatusPill.danger(String label, {IconData? icon}) => EmpStatusPill(
        label: label,
        bg: empDangerTint,
        fg: empDanger,
        icon: icon,
      );

  factory EmpStatusPill.neutral(String label, {IconData? icon}) => EmpStatusPill(
        label: label,
        bg: const Color(0xFFF0F4FD),
        fg: empMuted,
        icon: icon,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 4),
          ],
          Text(label, style: empSans(11, weight: FontWeight.w600, color: fg)),
        ],
      ),
    );
  }
}

/// Clean flat filter chip with 4px radius.
class EmpFilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  const EmpFilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? empPrimary : Colors.white,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: selected ? empPrimary : empBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13.5,
                  color: selected ? Colors.white : empMuted,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: empSans(
                  12,
                  weight: FontWeight.w600,
                  color: selected ? Colors.white : empMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet frame (mobile) / dialog content (desktop via showDialog).
class EmpSheetFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const EmpSheetFrame({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        18,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: empSans(17, weight: FontWeight.w700, color: empInk),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(subtitle!, style: empSans(12.5, color: empMuted)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: empMuted),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

InputDecoration empField(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: empSans(13, color: empMuted),
      hintStyle: empSans(13, color: empMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: empBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: empBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: empPrimary),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: empDanger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: const BorderSide(color: empDanger),
      ),
    );

ButtonStyle empPrimaryButton({double height = 40}) => FilledButton.styleFrom(
      backgroundColor: empPrimary,
      foregroundColor: Colors.white,
      minimumSize: Size(0, height),
      textStyle: empSans(13.5, weight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      elevation: 0,
    );

ButtonStyle empOutlineButton({double height = 40}) => OutlinedButton.styleFrom(
      foregroundColor: empInk,
      minimumSize: Size(0, height),
      textStyle: empSans(13.5, weight: FontWeight.w600),
      side: const BorderSide(color: empBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    );

// ============================================================================
// DEBOUNCED SEARCH FIELD — Use for all employee search/filter inputs.
// - Waits 250 ms after the user stops typing before firing onChanged.
// - Fires immediately on clear so the list resets without delay.
// - Cancels the timer on dispose to prevent setState-after-dispose crashes.
// ============================================================================

class EmpSearchField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;
  final Duration debounceDuration;

  const EmpSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
    this.debounceDuration = const Duration(milliseconds: 250),
  });

  @override
  State<EmpSearchField> createState() => _EmpSearchFieldState();
}

class _EmpSearchFieldState extends State<EmpSearchField> {
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged(String text) {
    if (widget.debounceDuration == Duration.zero) {
      widget.onChanged(text);
      return;
    }
    _debounceTimer?.cancel();
    // Immediate clear so list resets without waiting for debounce.
    if (text.isEmpty) {
      widget.onChanged(text);
      return;
    }
    _debounceTimer = Timer(widget.debounceDuration, () {
      if (mounted) widget.onChanged(text);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      onChanged: _onTextChanged,
      onSubmitted: (val) {
        _debounceTimer?.cancel();
        widget.onChanged(val);
      },
      style: empSans(14, color: empInk),
      cursorColor: empPrimary,
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: empSans(13.5, color: empMuted),
        prefixIcon: const Icon(Icons.search, size: 18, color: empMuted),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: empBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: empBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: empPrimary),
        ),
      ),
    );
  }
}
