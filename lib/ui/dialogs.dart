import 'package:flutter/material.dart';

import 'theme.dart';

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = 'Name',
  int maxLines = 1,
}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: maxLines,
          decoration: InputDecoration(labelText: label),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(context, v) : null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, ctl.text), child: const Text('OK')),
      ],
    ),
  ).then((v) => (v == null || v.trim().isEmpty) ? null : v);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String ok = 'Yes',
  bool destructive = true,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: ObsColors.live) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

const kColorSwatches = <int>[
  0xFFFFFFFF, 0xFF000000, 0xFF1E2230, 0xFF476BD7, 0xFF00B140, 0xFF00FF00,
  0xFFD7334B, 0xFFE0603A, 0xFFE3B341, 0xFF9C27B0, 0xFF00BCD4, 0xFF795548,
  0x00000000, 0x80000000,
];

/// Grid of tappable color swatches plus a hex field.
class ColorPickerField extends StatefulWidget {
  const ColorPickerField({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends State<ColorPickerField> {
  late final _hex = TextEditingController(text: _fmt(widget.value));

  static String _fmt(int v) => v.toRadixString(16).padLeft(8, '0').toUpperCase();

  @override
  void didUpdateWidget(ColorPickerField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _hex.text != _fmt(widget.value)) _hex.text = _fmt(widget.value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: const TextStyle(color: ObsColors.textDim)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final c in kColorSwatches)
              InkWell(
                onTap: () => widget.onChanged(c),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: c == widget.value ? ObsColors.accent : ObsColors.border,
                      width: c == widget.value ? 3 : 1,
                    ),
                  ),
                  child: (c >> 24) == 0
                      ? const Icon(Icons.block, size: 18, color: ObsColors.textDim)
                      : null,
                ),
              ),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _hex,
                decoration: const InputDecoration(prefixText: '#', isDense: true, labelText: 'AARRGGBB'),
                onSubmitted: (v) {
                  final parsed = int.tryParse(v.replaceAll('#', ''), radix: 16);
                  if (parsed != null) {
                    widget.onChanged(v.replaceAll('#', '').length <= 6 ? parsed | 0xFF000000 : parsed);
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Labeled slider row used throughout properties and settings.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.format,
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String Function(double)? format;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final slider = Slider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    final valueText = Text(format?.call(value) ?? value.toStringAsFixed(2), textAlign: TextAlign.right);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 320) {
        // Narrow docks: label and value above the slider.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(color: ObsColors.textDim)),
              ),
              valueText,
            ]),
            slider,
          ],
        );
      }
      return Row(
        children: [
          SizedBox(width: 120, child: Text(label, style: const TextStyle(color: ObsColors.textDim))),
          Expanded(child: slider),
          SizedBox(width: 72, child: valueText),
        ],
      );
    });
  }
}
