import 'package:flutter/material.dart';

/// Inserts markdown syntax around the current selection in [controller].
class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({super.key, required this.controller});

  final TextEditingController controller;

  void _wrap(String before, [String? after]) {
    final sel = controller.selection;
    final text = controller.text;
    final end = after ?? before;
    if (!sel.isValid || sel.start < 0) {
      controller.text = text + before;
      controller.selection = TextSelection.collapsed(
          offset: controller.text.length);
      return;
    }
    final selected = text.substring(sel.start, sel.end);
    controller.text =
        text.replaceRange(sel.start, sel.end, '$before$selected$end');
    controller.selection = TextSelection(
      baseOffset: sel.start + before.length,
      extentOffset: sel.start + before.length + selected.length,
    );
  }

  void _linePrefix(String prefix) {
    final sel = controller.selection;
    final text = controller.text;
    if (!sel.isValid || sel.start < 0) {
      controller.text = text + prefix;
      controller.selection =
          TextSelection.collapsed(offset: controller.text.length);
      return;
    }
    final lineStart = sel.start == 0 ? 0 : text.lastIndexOf('\n', sel.start - 1) + 1;
    controller.text = text.replaceRange(lineStart, lineStart, prefix);
    final shift = prefix.length;
    controller.selection = TextSelection(
      baseOffset: sel.start + shift,
      extentOffset: sel.end + shift,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          _Btn(icon: Icons.format_bold, onTap: () => _wrap('**')),
          _Btn(icon: Icons.format_italic, onTap: () => _wrap('_')),
          _Btn(
              icon: Icons.strikethrough_s,
              onTap: () => _wrap('~~')),
          _Btn(icon: Icons.code, onTap: () => _wrap('`')),
          const SizedBox(width: 8),
          _Btn(label: 'H1', style: style, onTap: () => _linePrefix('# ')),
          _Btn(label: 'H2', style: style, onTap: () => _linePrefix('## ')),
          _Btn(
              icon: Icons.format_list_bulleted,
              onTap: () => _linePrefix('- ')),
          _Btn(
              icon: Icons.format_list_numbered,
              onTap: () => _linePrefix('1. ')),
          _Btn(
              icon: Icons.check_box_outlined,
              onTap: () => _linePrefix('- [ ] ')),
          _Btn(
              icon: Icons.format_quote,
              onTap: () => _linePrefix('> ')),
          const SizedBox(width: 8),
          _Btn(
              icon: Icons.link,
              onTap: () => _wrap('[', '](https://)')),
          _Btn(
              icon: Icons.horizontal_rule,
              onTap: () => _linePrefix('\n---\n')),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({this.icon, this.label, this.style, required this.onTap});

  final IconData? icon;
  final String? label;
  final TextStyle? style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: icon != null
              ? Icon(icon, size: 18)
              : Text(label!,
                  style: (style ?? const TextStyle())
                      .copyWith(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}
