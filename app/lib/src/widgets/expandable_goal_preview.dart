import 'dart:math' show min;
import 'package:flutter/material.dart';

/// An opt-in larger reference with a full-size view, using the same renderer.
class ExpandableGoalPreview extends StatelessWidget {
  final Widget preview;
  final double maxSize;
  final Map<String, dynamic> labels;

  const ExpandableGoalPreview({
    super.key,
    required this.preview,
    required this.maxSize,
    this.labels = const {},
  });

  String _label(String key, String fallback) =>
      labels[key] is String ? labels[key] as String : fallback;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Reserve space for the playable board on shorter screens.
      final size = min(
        maxSize.isFinite && maxSize > 0 ? maxSize : 160.0,
        min(constraints.maxWidth, MediaQuery.sizeOf(context).height * .18),
      );
      return Center(
        child: Tooltip(
          message: _label('enlargeGoalTarget', 'Enlarge goal target'),
          child: Semantics(
            button: true,
            label: _label('enlargeGoalTarget', 'Enlarge goal target'),
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(_label('goalTarget', 'Goal target')),
                  content: SizedBox(
                    width: 420,
                    height: min(420, MediaQuery.sizeOf(context).height * .6),
                    child: InteractiveViewer(
                      maxScale: 3,
                      child: FittedBox(child: preview),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(MaterialLocalizations.of(context).closeButtonLabel),
                    ),
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: size,
                    height: size,
                    child: FittedBox(child: preview),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _label('tapToEnlarge', 'Tap to enlarge'),
                    style: TextStyle(fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
