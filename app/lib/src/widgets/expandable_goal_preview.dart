import 'dart:math' show min;
import 'package:flutter/material.dart';

/// An opt-in larger reference with a full-size view, using the same renderer.
class ExpandableGoalPreview extends StatelessWidget {
  final Widget preview;
  final double maxSize;

  const ExpandableGoalPreview({
    super.key,
    required this.preview,
    required this.maxSize,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Reserve space for the playable board on shorter screens.
      final size = min(
        maxSize,
        min(constraints.maxWidth, MediaQuery.sizeOf(context).height * .18),
      );
      return Center(
        child: Tooltip(
          message: 'Enlarge goal target',
          child: Semantics(
            button: true,
            label: 'Enlarge goal target',
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Goal target'),
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
                      child: const Text('Close'),
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
                  const Text(
                    'Tap to enlarge',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
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
