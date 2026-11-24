part of 'tile_placement_board.dart';

class _PlacementStyle {
  final ColorScheme scheme;
  final Map<String, String> palette;
  const _PlacementStyle(this.scheme, this.palette);

  Color color(String role) {
    final raw =
        palette['placement${role[0].toUpperCase()}${role.substring(1)}'];
    final hex = raw?.replaceAll('#', '');
    if (hex != null &&
        RegExp(r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(hex)) {
      return Color(int.parse(hex.length == 6 ? 'ff$hex' : hex, radix: 16));
    }
    return switch (role) {
      'surface' => scheme.surface,
      'surfaceAlt' => scheme.surfaceContainerHighest,
      'border' => scheme.outlineVariant,
      'text' => scheme.onSurface,
      'muted' => scheme.onSurfaceVariant,
      'primary' => scheme.primary,
      'primarySoft' => scheme.primaryContainer,
      'warning' => scheme.tertiary,
      'error' => scheme.error,
      _ => scheme.onSurface,
    };
  }
}

Color _tileColor(dynamic raw) => Color(
  0xff000000 |
      (int.tryParse('$raw'.replaceAll('#', ''), radix: 16) ??
          Colors.blueGrey.toARGB32()),
);

Color _darken(Color c, [double factor = 0.16]) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness((hsl.lightness - factor).clamp(0.0, 1.0)).toColor();
}

class _TilePainter extends CustomPainter {
  final Map<String, dynamic> c;
  final _PlacementStyle style;
  final Map placed;
  final int phase, rotation, transferSteps, removalsUsed, activeVariant;
  final List lights, moved;
  final String? selected;
  final Position? hover;
  final bool interactive, lightOnly, isThumbnail;

  _TilePainter(
    this.style,
    this.c,
    this.placed,
    this.phase,
    this.lights,
    this.selected,
    this.hover,
    this.interactive, {
    this.rotation = 0,
    this.activeVariant = 0,
    this.transferSteps = 0,
    this.removalsUsed = 0,
    this.moved = const [],
    this.lightOnly = false,
    this.isThumbnail = false,
  });

  void label(
    Canvas canvas,
    String text,
    Offset center,
    double size, {
    Color color = Colors.white,
    bool shadow = false,
  }) {
    if (shadow) {
      final s = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'Roboto',
            color: Colors.black.withValues(alpha: 0.35),
            fontSize: size,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      s.paint(canvas, center - Offset(s.width / 2 - 0.7, s.height / 2 - 0.7));
    }
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          color: color,
          fontSize: size,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, center - Offset(p.width / 2, p.height / 2));
  }

  // Keep the number inside the piece; point to the exact connecting side.
  void edgeBadge(
    Canvas canvas,
    Position point,
    int direction,
    String symbol,
    double cell,
  ) {
    const steps = [Offset(0, -1), Offset(1, 0), Offset(0, 1), Offset(-1, 0)];
    final delta = steps[direction];
    final center =
        Offset((point.x + .5) * cell, (point.y + .5) * cell) +
        delta * (cell * (isThumbnail ? .48 : .32));
    final radius = isThumbnail
        ? min(6.0, cell * .24)
        : min(14.0, max(9.0, cell * .20));
    final tip =
        Offset((point.x + .5) * cell, (point.y + .5) * cell) +
        delta * (cell * (isThumbnail ? .85 : .62));
    final side = Offset(-delta.dy, delta.dx);
    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = style.color('primary')
        ..strokeWidth = 2.5,
    );
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          (tip - delta * 5 + side * 3).dx,
          (tip - delta * 5 + side * 3).dy,
        )
        ..lineTo(
          (tip - delta * 5 - side * 3).dx,
          (tip - delta * 5 - side * 3).dy,
        )
        ..close(),
      Paint()..color = style.color('primary'),
    );
    canvas.drawCircle(center, radius + 1.5, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius, Paint()..color = style.color('primary'));
    label(
      canvas,
      symbol,
      center,
      isThumbnail ? min(10.0, cell * .48) : min(15.0, max(12.0, cell * .24)),
      color: Colors.white,
      shadow: false,
    );
  }

  Rect rect(Position p, double cell) =>
      Rect.fromLTWH(p.x * cell + 1.5, p.y * cell + 1.5, cell - 3, cell - 3);

  Path silhouette(List<Position> points, double cell) {
    final occupied = points.toSet();
    var shape = Path();
    for (final p in points) {
      final top = occupied.contains(Position(p.x, p.y - 1)),
          bottom = occupied.contains(Position(p.x, p.y + 1));
      final left = occupied.contains(Position(p.x - 1, p.y)),
          right = occupied.contains(Position(p.x + 1, p.y));
      final radius = Radius.circular(cell * .12);
      final tile = RRect.fromRectAndCorners(
        Rect.fromLTRB(
          p.x * cell + (left ? 0 : 2),
          p.y * cell + (top ? 0 : 2),
          (p.x + 1) * cell - (right ? 0 : 2),
          (p.y + 1) * cell - (bottom ? 0 : 2),
        ),
        topLeft: !top && !left ? radius : Radius.zero,
        topRight: !top && !right ? radius : Radius.zero,
        bottomLeft: !bottom && !left ? radius : Radius.zero,
        bottomRight: !bottom && !right ? radius : Radius.zero,
      );
      shape = Path.combine(PathOperation.union, shape, Path()..addRRect(tile));
    }
    return shape;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final targets = TilePlacementSystem.points(c['targets'][phase]),
        pieces = TilePlacementSystem.pieces(c);
    final chosen = selected == null
        ? null
        : pieces.firstWhere((p) => p['id'] == selected);
    final selectedPose = hover == null || chosen == null
        ? null
        : [
            hover!.x,
            hover!.y,
            rotation,
            if (chosen['variants'] != null) activeVariant,
          ];
    final previews = !interactive || selectedPose == null
        ? <String, List<dynamic>>{}
        : TilePlacementSystem.linkedPlacements(
            c,
            placed,
            selected!,
            selectedPose,
          );
    final width = (c['size'] as List)[0] as int, height = c['size'][1] as int;
    final cell = min(size.width / width, size.height / height);
    final on = TilePlacementSystem.points(lights).toSet();
    final target = targets.toSet(), owner = <Position, String>{};
    final movement = interactive
        ? ((phase > 0 ? c['transfer'] : null) ??
                  c['insertion'] ??
                  (c['playArea'] == null ? null : {'area': c['playArea']}))
              as Map?
        : null;
    final transit = movement == null
        ? <Position>{}
        : TilePlacementSystem.points(movement['area']).toSet();
    final marked = <String, Map<String, dynamic>>{};

    for (final entry in placed.entries) {
      if (previews.containsKey(entry.key)) continue;
      final p = pieces.firstWhere((p) => p['id'] == entry.key);
      for (final point in TilePlacementSystem.cells(p, entry.value as List)) {
        owner[point] = entry.key as String;
      }
      for (final e in TilePlacementSystem.edges(p, entry.value as List)) {
        final a = e['position'] as Position;
        marked['${a.x},${a.y},${e['direction']}'] = {
          'id': entry.key,
          'symbol': e['symbol'],
        };
      }
    }

    for (final entry in previews.entries) {
      final piece = pieces.firstWhere((p) => p['id'] == entry.key);
      for (final edge in TilePlacementSystem.edges(piece, entry.value)) {
        final point = edge['position'] as Position;
        marked['${point.x},${point.y},${edge['direction']}'] = {
          'id': entry.key,
          'symbol': edge['symbol'],
        };
      }
    }
    final releasePads = TilePlacementSystem.points(
      (c['linkedMovement'] as Map?)?['releaseCells'] ?? [],
    ).toSet();
    final releasedPieces = {
      for (final entry in {...placed, ...previews}.entries)
        if (TilePlacementSystem.cells(
          pieces.firstWhere((p) => p['id'] == entry.key),
          entry.value as List,
        ).any(releasePads.contains))
          entry.key,
    };
    void drawClasp(Position a, Position delta, String symbol) {
      final center = Offset(
        (a.x + .5 + delta.x * .5) * cell,
        (a.y + .5 + delta.y * .5) * cell,
      );
      final horizontal = delta.x != 0;
      final w = max(22.0, cell * (horizontal ? .52 : .36));
      final h = max(22.0, cell * (horizontal ? .36 : .52));
      final capsule = RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: w, height: h),
        Radius.circular(min(w, h) * .5),
      );
      canvas.drawRRect(capsule, Paint()..color = style.color('text'));
      canvas.drawRRect(
        capsule,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      label(
        canvas,
        symbol,
        center,
        min(16.0, max(12.0, cell * .25)),
        color: Colors.white,
        shadow: true,
      );
    }

    final markers = {
      for (final m in c['markers'] as List? ?? [])
        Position.fromJson(m['position']): m['color'],
    };

    // 1. Draw Board Grid & Slots (skipped for piece card thumbnails!)
    if (!isThumbnail) {
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final p = Position(x, y);
          final isTarget = target.contains(p);
          if (!interactive && !isTarget) continue;
          if (c['silhouetteMode'] == true &&
              !isTarget &&
              !transit.contains(p)) {
            continue;
          }
          final r = RRect.fromRectAndRadius(
            interactive
                ? rect(p, cell)
                : Rect.fromLTWH(
                    x * cell + .2,
                    y * cell + .2,
                    cell - .4,
                    cell - .4,
                  ),
            Radius.circular(cell * .12),
          );

          if (isTarget) {
            // Crisp bright goal slot so the target silhouette stands out clearly.
            canvas.drawRRect(
              r,
              Paint()
                ..color = interactive
                    ? c['targetFill'] != null
                          ? _tileColor(c['targetFill'])
                          : Colors.white
                    : c['boardAccent'] != null
                    ? _tileColor(c['boardAccent'])
                    : style.color('primary'),
            );
            canvas.drawRRect(
              r,
              Paint()
                ..color = c['boardAccent'] != null
                    ? _tileColor(c['boardAccent']).withValues(alpha: .65)
                    : movement == null
                    ? style.color('muted')
                    : style.color('muted')
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2,
            );
          } else if (transit.contains(p)) {
            canvas.drawRRect(r, Paint()..color = style.color('primarySoft'));
            canvas.drawRRect(
              r,
              Paint()
                ..color = style.color('border')
                ..style = PaintingStyle.stroke
                ..strokeWidth = .8,
            );
          } else {
            // Solid dark slate-gray unusable block (distinct from white goal & pale transit).
            canvas.drawRRect(r, Paint()..color = style.color('text'));
            canvas.drawRRect(
              r,
              Paint()
                ..color = style.color('primary')
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2,
            );
          }

          // Optional circular board markers
          if (markers.containsKey(p)) {
            final center = Offset((x + .75) * cell, (y + .25) * cell);
            canvas.drawCircle(
              center,
              cell * .12,
              Paint()..color = _tileColor(markers[p]),
            );
            canvas.drawCircle(
              center,
              cell * .12,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          }

          // Light goals or states
          if ((c['lights'] != null || lightOnly) && target.contains(p)) {
            final center = Offset((x + .5) * cell, (y + .5) * cell);
            canvas.drawCircle(
              center,
              cell * .18,
              Paint()
                ..color = on.contains(p)
                    ? style.color('warning')
                    : style.color('text'),
            );
            canvas.drawCircle(
              center,
              cell * .18,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.5,
            );
          }
        }
      }
    }

    // Each rigid piece is a single matte silhouette, not a stack of beveled cells.
    for (final entry in placed.entries) {
      if (previews.containsKey(entry.key)) continue;
      final key = entry.key as String;
      final piece = pieces.firstWhere((p) => p['id'] == key);
      final pts = TilePlacementSystem.cells(piece, entry.value as List);
      final color = _tileColor(piece['color']);
      final shape = silhouette(pts, cell);
      if (!isThumbnail) {
        canvas.drawShadow(
          shape,
          style.color('primary').withValues(alpha: .12),
          3,
          true,
        );
      }
      canvas.drawPath(shape, Paint()..color = color);
      canvas.drawPath(
        shape,
        Paint()
          ..color = _darken(color, .07).withValues(alpha: .55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8,
      );
      if (!isThumbnail && pts.isNotEmpty) {
        final anchor = pts.reduce(
          (a, b) => a.y < b.y || a.y == b.y && a.x < b.x ? a : b,
        );
        label(
          canvas,
          key.toUpperCase(),
          Offset((anchor.x + .24) * cell, (anchor.y + .7) * cell),
          min(12, cell * .2),
          color: _darken(color, .35),
        );
        if (piece['entrySide'] != null) {
          const arrows = ['\u2193', '\u2190', '\u2191', '\u2192'];
          label(
            canvas,
            arrows[piece['entrySide'] as int],
            Offset((anchor.x + .72) * cell, (anchor.y + .67) * cell),
            min(16, cell * .30),
            color: _darken(color, .35),
          );
        }
      }
      if (piece['value'] != null) {
        for (final point in pts) {
          label(
            canvas,
            '${piece['value']}',
            Offset((point.x + .5) * cell, (point.y + .5) * cell),
            min(24, cell * .38),
          );
        }
      }
    }

    // 3. Stacking / Support floor beam (skipped in thumbnails)
    if (!isThumbnail && c['support'] == true) {
      final floorY = height * cell;
      canvas.drawRect(
        Rect.fromLTWH(0, floorY - 4, width * cell, 6),
        Paint()..color = style.color('warning'),
      );
      canvas.drawLine(
        Offset(0, floorY - 4),
        Offset(width * cell, floorY - 4),
        Paint()
          ..color = style.color('warning')
          ..strokeWidth = 1.5,
      );
    }

    if (!isThumbnail) {
      final release = TilePlacementSystem.points(
        (c['linkedMovement'] as Map?)?['releaseCells'] ?? [],
      );
      final workshops = TilePlacementSystem.points(c['variantCells'] ?? []);
      for (final point in [...release, ...workshops]) {
        final center = Offset((point.x + .5) * cell, (point.y + .5) * cell);
        canvas.drawCircle(
          center,
          cell * .25,
          Paint()..color = Colors.white.withValues(alpha: .9),
        );
        canvas.drawCircle(
          center,
          cell * .25,
          Paint()
            ..color = style.color('primary')
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
        final d = cell * .13;
        final icon = Path();
        if (release.contains(point)) {
          icon.moveTo(center.dx, center.dy - d);
          icon.lineTo(center.dx + d, center.dy);
          icon.lineTo(center.dx, center.dy + d);
          icon.lineTo(center.dx - d, center.dy);
          icon.close();
        } else {
          icon.moveTo(center.dx - d, center.dy - d * .45);
          icon.lineTo(center.dx + d, center.dy - d * .45);
          icon.lineTo(center.dx + d * .45, center.dy - d * .95);
          icon.moveTo(center.dx + d, center.dy + d * .45);
          icon.lineTo(center.dx - d, center.dy + d * .45);
          icon.lineTo(center.dx - d * .45, center.dy + d * .95);
        }
        canvas.drawPath(
          icon,
          Paint()
            ..color = style.color('primary')
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    const directions = [
      Position(0, -1),
      Position(1, 0),
      Position(0, 1),
      Position(-1, 0),
    ];

    // 4. Edge Connectors & Pulse
    final drawnMatches = <String>{};

    for (final entry in placed.entries) {
      if (previews.containsKey(entry.key)) continue;
      final p = pieces.firstWhere((p) => p['id'] == entry.key),
          placement = entry.value as List;
      if (!isThumbnail && p['pulse'] != null) {
        final a =
            TilePlacementSystem.transform(
              p,
              Position.fromJson(p['pulse']),
              placement[2] as int,
            ) +
            Position(placement[0] as int, placement[1] as int);
        label(
          canvas,
          '✦',
          Offset((a.x + .25) * cell, (a.y + .25) * cell),
          min(22, cell * .38),
          color: style.color('warning'),
        );
      }
      for (final e in TilePlacementSystem.edges(p, placement)) {
        final a = e['position'] as Position,
            d = e['direction'] as int,
            delta = directions[d],
            next = a + delta;
        final other = marked['${next.x},${next.y},${(d + 2) % 4}'];
        final matches =
            other != null &&
            other['id'] != entry.key &&
            other['symbol'] == e['symbol'] &&
            !releasedPieces.contains(entry.key) &&
            !releasedPieces.contains(other['id']);
        final isConflict =
            other != null && other['id'] != entry.key && !matches;

        if (matches) {
          // Draw unified magnetic clasp ONCE directly on the seam
          final seamKey = a.x < next.x || (a.x == next.x && a.y < next.y)
              ? '${a.x},${a.y}-${next.x},${next.y}'
              : '${next.x},${next.y}-${a.x},${a.y}';
          if (drawnMatches.add(seamKey)) {
            drawClasp(a, delta, '${e['symbol']}');
          }
        } else if (isConflict) {
          final seamCenter = Offset(
            (a.x + 0.5 + delta.x * 0.5) * cell,
            (a.y + 0.5 + delta.y * 0.5) * cell,
          );
          canvas.drawCircle(
            seamCenter,
            cell * 0.16,
            Paint()..color = style.color('error'),
          );
          canvas.drawCircle(
            seamCenter,
            cell * 0.16,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
          label(
            canvas,
            '✕',
            seamCenter,
            min(12.0, max(8.0, cell * 0.18)),
            color: Colors.white,
            shadow: false,
          );
        } else {
          edgeBadge(canvas, a, d, '${e['symbol']}', cell);
        }
      }
    }

    // The preview includes every member of a linked group.
    if (!isThumbnail && interactive && selectedPose != null) {
      final valid =
          TilePlacementSystem.problem(
            c,
            placed,
            phase,
            moved,
            selected,
            selectedPose,
            steps: transferSteps,
            lifts: removalsUsed,
          ) ==
          null;
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (final e in previews.entries) {
        final piece = pieces.firstWhere((p) => p['id'] == e.key),
            placement = e.value;
        final points = TilePlacementSystem.cells(piece, placement),
            color = _tileColor(piece['color']);
        final path = silhouette(points, cell);
        canvas.drawPath(
          path,
          Paint()..color = color.withValues(alpha: valid ? .85 : .5),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = valid ? _darken(color, .12) : style.color('error')
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        if (points.isNotEmpty) {
          final p = points.first;
          label(
            canvas,
            e.key.toUpperCase(),
            Offset((p.x + .24) * cell, (p.y + .7) * cell),
            min(12.0, cell * .2),
            color: _darken(color, .35),
          );
        }
        if (piece['pulse'] != null) {
          final p =
              TilePlacementSystem.transform(
                piece,
                Position.fromJson(piece['pulse']),
                placement[2] as int,
              ) +
              Position(placement[0] as int, placement[1] as int);
          label(
            canvas,
            '\u2726',
            Offset((p.x + .25) * cell, (p.y + .25) * cell),
            min(22.0, cell * .38),
            color: style.color('warning'),
          );
        }
      }
      for (final entry in previews.entries) {
        final piece = pieces.firstWhere((p) => p['id'] == entry.key);
        for (final edge in TilePlacementSystem.edges(piece, entry.value)) {
          final point = edge['position'] as Position;
          final direction = edge['direction'] as int;
          final delta = directions[direction], next = point + delta;
          final other = marked['${next.x},${next.y},${(direction + 2) % 4}'];
          final matches =
              other != null &&
              other['id'] != entry.key &&
              other['symbol'] == edge['symbol'] &&
              !releasedPieces.contains(entry.key) &&
              !releasedPieces.contains(other['id']);
          if (matches) {
            final seam =
                point.x < next.x || (point.x == next.x && point.y < next.y)
                ? '${point.x},${point.y}-${next.x},${next.y}'
                : '${next.x},${next.y}-${point.x},${point.y}';
            if (drawnMatches.add(seam)) {
              drawClasp(point, delta, '${edge['symbol']}');
            }
          } else {
            edgeBadge(canvas, point, direction, '${edge['symbol']}', cell);
          }
        }
      }
      canvas.restore();
    }
    final decorations = (c['targetDecorations'] as List? ?? []);
    if (!isThumbnail && phase < decorations.length) {
      for (final item in decorations[phase] as List) {
        final position = item['position'] as List;
        final center = Offset(
          (position[0] as num).toDouble() * cell,
          (position[1] as num).toDouble() * cell,
        );
        final radius = (item['radius'] as num).toDouble() * cell;
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = _tileColor(item['color']),
        );
        canvas.drawCircle(
          center - Offset(radius * .28, radius * .3),
          radius * .24,
          Paint()..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter oldDelegate) => true;
}
