import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Only authored public alternatives belong here. Never pass runtime nodes.
class PublicCircuitNode {
  final String id;
  final List<Map> alternatives;
  final List start;
  PublicCircuitNode(Map data)
    : id = data['id'] as String,
      alternatives = (data['alternatives'] as List).cast<Map>(),
      start = data['start'] as List;

  Set<String> get sources =>
      alternatives.expand((a) => (a['inputs'] as List).cast<String>()).toSet();
  bool certainSource(String source) =>
      alternatives.every((a) => (a['inputs'] as List).contains(source));
  String get startLabel => start.length > 1
      ? 'Start ?'
      : 'Start ${start.single == 1 ? 'ON' : 'OFF'}';
  String get formula => alternatives
      .map(
        (a) =>
            '${a['op'].toString().toUpperCase()}(${(a['inputs'] as List).join(',').toUpperCase()})',
      )
      .join('\nor ');

  String explain(Map a) {
    final inputs = (a['inputs'] as List)
        .map((s) => s.toString().toUpperCase())
        .toList();
    final pair = inputs.join(' and ');
    return switch (a['op']) {
      'copy' => 'copies ${inputs.first}',
      'not' =>
        inputs.first == id
            ? 'flips itself every test'
            : 'takes the opposite of ${inputs.first}',
      'toggle' =>
        'flips its memory when ${inputs.first} is ON; otherwise keeps it',
      'xor' => 'turns ON when $pair differ',
      'and' => 'turns ON only when $pair are both ON',
      'or' => 'turns ON when either of $pair is ON',
      _ => formula,
    };
  }
}

class NetworkClueDetail extends StatelessWidget {
  final PublicCircuitNode node;
  final List pairs;
  final bool held;
  const NetworkClueDetail({
    super.key,
    required this.node,
    required this.pairs,
    required this.held,
  });

  @override
  Widget build(BuildContext context) {
    final pairing = pairs
        .map(
          (p) =>
              'A←${p[0].toString().toUpperCase()}, B←${p[1].toString().toUpperCase()}',
        )
        .join(' OR ');
    return Container(
      key: const ValueKey('circuit-clue-detail'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F7F7),
        border: Border.all(color: const Color(0xFF95B9BB)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${node.id} · public circuit clue · ${node.startLabel}${node.start.length > 1 ? ' (ON or OFF)' : ''}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              Text(
                'Next test: ${node.id} ${node.alternatives.map(node.explain).join(' OR ')}.',
                style: const TextStyle(fontSize: 13),
              ),
              if (pairs.isNotEmpty && (node.id == 'A' || node.id == 'B'))
                Text(
                  'Paired wiring: $pairing. They use different switches.',
                  style: const TextStyle(fontSize: 13),
                ),
              Text(
                held
                    ? '${node.id} is held OFF: downstream modules receive OFF; its memory still updates.'
                    : 'Module sources use their PREVIOUS output; switches use your new setting. A clue is not a measurement.',
                style: const TextStyle(fontSize: 12, color: Color(0xFF41666B)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draw just the inspected module's inputs, avoiding an unreadable full harness.
/// Solid edges occur in every alternative; dashed edges occur in some only.
class CircuitCluePainter extends CustomPainter {
  final PublicCircuitNode node;
  final Map<String, Offset> positions;
  final double cell;
  CircuitCluePainter({
    required this.node,
    required this.positions,
    required this.cell,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final target = positions[node.id];
    if (target == null) return;
    for (final source in node.sources) {
      final origin = positions[source];
      if (origin == null) continue;
      final certain = node.certainSource(source);
      final paint = Paint()
        ..color = certain ? const Color(0xFF18777C) : const Color(0xFFB46B14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, cell * .035)
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      Offset end;
      Offset beforeEnd;
      if (source == node.id) {
        // Self-feedback wraps above the module, not through its own sprite.
        final start = origin + Offset(-.38, -.12) * cell;
        end = target + Offset(.05, -.40) * cell;
        beforeEnd = target + Offset(.05, -.68) * cell;
        path.moveTo(start.dx, start.dy);
        path.lineTo(origin.dx - .58 * cell, start.dy);
        path.lineTo(origin.dx - .58 * cell, beforeEnd.dy);
        path.lineTo(beforeEnd.dx, beforeEnd.dy);
        path.lineTo(end.dx, end.dy);
      } else if (source.toLowerCase() == source &&
          origin.dy < target.dy &&
          (origin.dx - target.dx).abs() < cell) {
        final start = origin + Offset(0, .4) * cell;
        end = target + Offset(0, -.4) * cell;
        beforeEnd = start;
        path.moveTo(start.dx, start.dy);
        path.lineTo(end.dx, end.dy);
      } else {
        // The left gutters and the gap above each module row are empty.
        final start = origin + Offset(.38, -.15) * cell;
        final lane = target.dy - .65 * cell;
        final gutter = target.dx - .48 * cell;
        end = target + Offset(-.38, -.18) * cell;
        beforeEnd = Offset(gutter, end.dy);
        path.moveTo(start.dx, start.dy);
        path.lineTo(origin.dx + .48 * cell, start.dy);
        path.lineTo(origin.dx + .48 * cell, lane);
        path.lineTo(gutter, lane);
        path.lineTo(beforeEnd.dx, beforeEnd.dy);
        path.lineTo(end.dx, end.dy);
      }
      if (certain) {
        canvas.drawPath(path, paint);
      } else {
        for (final metric in path.computeMetrics()) {
          for (double d = 0; d < metric.length; d += cell * .15) {
            canvas.drawPath(
              metric.extractPath(d, math.min(d + cell * .09, metric.length)),
              paint,
            );
          }
        }
      }
      final angle = math.atan2(end.dy - beforeEnd.dy, end.dx - beforeEnd.dx);
      final arrow = Path()..moveTo(end.dx, end.dy);
      for (final sign in [-1, 1]) {
        final point =
            end -
            Offset(math.cos(angle + sign * .55), math.sin(angle + sign * .55)) *
                cell *
                .11;
        arrow.lineTo(point.dx, point.dy);
        arrow.moveTo(end.dx, end.dy);
      }
      canvas.drawPath(arrow, paint);
      canvas.drawCircle(origin, cell * .43, paint..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(covariant CircuitCluePainter oldDelegate) => true;
}
