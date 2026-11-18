import 'dart:math' show min, max;

import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';

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

/// Tray and direct placement surface for the opt-in tile_placement system.
class TilePlacementBoard extends StatefulWidget {
  final String systemId;
  final Map<String, dynamic> config;
  final LevelState state;
  final ValueChanged<GameAction>? onAction;
  final VoidCallback onReset;
  final Map<String, String> palette;
  final Map<String, dynamic> labels;
  const TilePlacementBoard({
    super.key,
    required this.systemId,
    required this.config,
    required this.state,
    required this.onAction,
    required this.onReset,
    this.palette = const {},
    this.labels = const {},
  });
  @override
  State<TilePlacementBoard> createState() => _TilePlacementBoardState();
}

class _TilePlacementBoardState extends State<TilePlacementBoard> {
  _PlacementStyle get style =>
      _PlacementStyle(Theme.of(context).colorScheme, widget.palette);
  String label(String text) =>
      widget.labels[text] is String ? widget.labels[text] as String : text;
  String? selected;
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  final rotations = <String, int>{};
  Position? hover;
  Position grabOffset = Position(0, 0);
  Map<String, dynamic> get c => widget.config;
  String get prefix => '${widget.systemId}.';
  dynamic value(String key) => widget.state.variables['$prefix$key'];
  Map get placed => value('placements') as Map? ?? {};
  int get phase => value('phase') as int? ?? 0;
  List get moved => value('moved') as List? ?? [];
  List<Map<String, dynamic>> get pieces => TilePlacementSystem.pieces(c);
  int angle(String id) {
    if (c['limits'] != null) {
      return (value('previewRotations') as Map?)?[id] as int? ?? 0;
    }
    if (c['rotationLinks'] != null) {
      return (value('orientations') as Map?)?[id] as int? ?? 0;
    }
    final settled = placed[id] as List?;
    if (selected != id && settled != null) return settled[2] as int;
    return rotations[id] ?? (settled == null ? 0 : settled[2] as int);
  }

  int form(String id) => (value('forms') as Map?)?[id] as int? ?? 0;
  List pose(String id, Position p) => [
    p.x,
    p.y,
    angle(id),
    if (pieces.firstWhere((v) => v['id'] == id)['variants'] != null) form(id),
  ];
  String? error(String id, Position p) => TilePlacementSystem.problem(
    c,
    placed,
    phase,
    moved,
    id,
    pose(id, p),
    steps: value('transferSteps') as int? ?? 0,
    lifts: value('removalsUsed') as int? ?? 0,
  );
  void choose(String id, [Position? grabbed]) => setState(() {
    selected = id;
    final old = placed[id] as List?;
    grabOffset = grabbed != null && old != null
        ? Position(grabbed.x - (old[0] as int), grabbed.y - (old[1] as int))
        : Position(0, 0);
    hover = grabbed != null && old != null
        ? Position(old[0] as int, old[1] as int)
        : null;
    rotations[id] = placed[id] is List
        ? (placed[id] as List)[2] as int
        : angle(id);
  });
  String targetName(int index) {
    final names = c['targetLabels'];
    return names is List && index < names.length && names[index] is String
        ? names[index] as String
        : '${label('Shape')} ${index + 1}';
  }

  void _showTargetPreviewDialog(BuildContext context, int initialIndex) {
    final targets = c['targets'] as List;
    final w = (c['size'][0] as num).toDouble();
    final h = (c['size'][1] as num).toDouble();
    var active = initialIndex.clamp(0, targets.length - 1);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final targetCells = targets[active] as List;
          final viewport = MediaQuery.sizeOf(context);
          final scale = min(
            min(460.0, max(1.0, viewport.width - 148)) / w,
            min(340.0, max(48.0, viewport.height - 220)) / h,
          );
          final paintW = w * scale, paintH = h * scale;
          return Dialog(
            backgroundColor: style.color('surface'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                targets.length > 1
                                    ? '${targetName(active)} (${active + 1}/${targets.length})'
                                    : 'Target Goal',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: style.color('primary'),
                                ),
                              ),
                              Text(
                                '${targetCells.length} squares to fill',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: style.color('muted'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          icon: Icon(Icons.close_rounded),
                          tooltip: label('Close'),
                        ),
                      ],
                    ),
                    if (targets.length > 1) ...[
                      SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (var i = 0; i < targets.length; i++)
                            ChoiceChip(
                              label: Text(targetName(i)),
                              selected: i == active,
                              onSelected: (_) =>
                                  setDialogState(() => active = i),
                            ),
                        ],
                      ),
                    ],
                    SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: style.color('primarySoft'),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: style.color('surfaceAlt')),
                      ),
                      child: SizedBox(
                        width: paintW,
                        height: paintH,
                        child: CustomPaint(
                          painter: _TilePainter(
                            style,
                            c,
                            {},
                            active,
                            const [],
                            null,
                            null,
                            false,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String? configuredEchoPartner(String id) {
    for (final pair in c['echoLinks'] as List? ?? []) {
      if ((pair as List).contains(id)) {
        return (pair[0] == id ? pair[1] : pair[0]) as String;
      }
    }
    return null;
  }

  String magneticStatus() {
    if (selected == null) {
      return (c['linkedMovement'] as Map?)?['releaseCells'] == null
          ? 'Choose your connections. Bonds stay joined; use Undo to revise them.'
          : 'Align matching numbered edges face-to-face to lock pieces.';
    }
    final group = TilePlacementSystem.linkedGroup(c, placed, selected!);
    if (group.length > 1) {
      return '${(c['linkedMovement'] as Map?)?['releaseCells'] == null ? 'Permanent bond' : 'Linked group'}: ${group.map((s) => s.toUpperCase()).join(' + ')}';
    }
    final placement = placed[selected] as List?;
    final pads = TilePlacementSystem.points(
      (c['linkedMovement'] as Map?)?['releaseCells'] ?? [],
    ).toSet();
    final piece = pieces.firstWhere((p) => p['id'] == selected);
    if (placement != null &&
        TilePlacementSystem.cells(piece, placement).any(pads.contains)) {
      return '${selected!.toUpperCase()} is on the release pad: connections are open.';
    }
    return '${selected!.toUpperCase()} is not linked. Equal numbers must face each other.';
  }

  void cancelSelection() {
    if (selected == null) return;
    setState(() {
      selected = null;
      hover = null;
      grabOffset = Position(0, 0);
    });
  }

  Widget selectionRegion(Widget child, {bool dismissOutside = false}) =>
      TapRegion(
        groupId: this,
        onTapOutside: dismissOutside ? (_) => cancelSelection() : null,
        child: child,
      );

  void returnSelected() {
    if (selected == null || widget.onAction == null) return;
    widget.onAction!(
      GameAction(c['removeAction'] as String? ?? 'remove_piece', {
        'piece': selected,
      }),
    );
    setState(() {
      hover = null;
      grabOffset = Position(0, 0);
    });
  }

  void rotateSelected() {
    if (selected == null) return;
    if (c['limits'] != null) {
      widget.onAction?.call(
        GameAction(c['rotateAction'] as String? ?? 'rotate_piece', {
          'piece': selected,
        }),
      );
      setState(() {});
      return;
    }
    if (c['rotationLinks'] != null) {
      widget.onAction?.call(
        GameAction(c['turnAction'] as String? ?? 'turn_piece', {
          'piece': selected,
        }),
      );
      setState(() {
        hover = null;
        grabOffset = Position(0, 0);
      });
    } else {
      setState(() => rotations[selected!] = (angle(selected!) + 1) % 4);
    }
  }

  void swapSelected() {
    if (selected == null || widget.onAction == null) return;
    widget.onAction!(
      GameAction(c['swapAction'] as String? ?? 'swap_echo', {
        'piece': selected,
      }),
    );
    setState(() {
      hover = null;
      grabOffset = Position(0, 0);
    });
  }

  void changeSelected() {
    if (selected == null || widget.onAction == null) return;
    widget.onAction!(
      GameAction(c['changeAction'] as String? ?? 'change_piece', {
        'piece': selected,
      }),
    );
    setState(() {
      hover = null;
      grabOffset = Position(0, 0);
    });
  }

  void put(String id, Position p) {
    if (widget.onAction == null) return;
    final problem = error(id, p);
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.info_outline, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text(problem)),
            ],
          ),
          backgroundColor: style.color('primary'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    widget.onAction!(
      GameAction(c['placeAction'] as String? ?? 'place_piece', {
        'piece': id,
        'position': p.toJson(),
        'rotation': angle(id),
      }),
    );
    setState(() {
      selected = null;
      hover = null;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final w = widget.state.board.width, h = widget.state.board.height;
      final limits = c['limits'] as Map?;
      final noRotations =
          limits != null &&
          (value('rotationsUsed') as int? ?? 0) >= (limits['rotations'] as int);
      final crossSums = c['rowTotals'] != null && c['columnTotals'] != null;
      final wide = constraints.maxWidth >= 820;
      final permanent =
          c['linkedMovement'] != null &&
          (c['linkedMovement'] as Map)['releaseCells'] == null;
      final echoPartner = selected == null
          ? null
          : TilePlacementSystem.echoPartner(c, placed, selected!);
      final bonded =
          echoPartner != null ||
          (selected != null &&
              permanent &&
              TilePlacementSystem.linkedGroup(c, placed, selected!).length > 1);
      final mixed =
          c['linkedMovement'] != null &&
          c['variantCells'] != null &&
          c['neighborCounts'] != null;
      final contentWidth = min(1040.0, constraints.maxWidth);
      final boardWidth = wide ? contentWidth - 364 : contentWidth;
      final cell = min(
        wide ? 80.0 : 60.0,
        min(
          // Include surface padding and its 1px border on both sides. A
          // clamped SizedBox otherwise paints narrower than the hit-test grid.
          (boardWidth - (wide ? 50 : 34) - (crossSums ? 44 : 0)) / w,
          wide
              ? max(
                  mixed
                      ? 10.0
                      : limits != null
                      ? 12.0
                      : 16.0,
                  (constraints.maxHeight -
                          (mixed
                              ? 330
                              : (c['targets'] as List).length > 1
                              ? 260
                              : 200) -
                          (limits != null ? 45 : 0) -
                          (c['allowUnused'] == true ? 15 : 0)) /
                      h,
                )
              : double.infinity,
        ),
      );
      final targets = c['targets'] as List;
      final transfer = c['transfer'] as Map?;
      final insertion = c['insertion'] as Map?;
      final rotationBlocked =
          placed.containsKey(selected) &&
          (insertion != null || (phase > 0 && transfer?['slideOnly'] == true));
      final selectedPiece = selected == null
          ? null
          : pieces.firstWhere((p) => p['id'] == selected);
      final canChange =
          selected != null &&
          placed[selected] is List &&
          selectedPiece!['variants'] != null &&
          TilePlacementSystem.cells(
            selectedPiece,
            placed[selected] as List,
          ).any(
            TilePlacementSystem.points(
              c['variantCells'] ?? [],
            ).toSet().contains,
          );
      final lights = c['lights'] as Map?;
      final total = (targets[phase] as List).length;
      final filled = value('filled') as int? ?? 0;
      final extras = <Widget>[
        // Row Totals indicator (if configured)
        if (c['rowTotals'] != null && !crossSums)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                for (var row = 0; row < (c['rowTotals'] as List).length; row++)
                  _rowChip(
                    row,
                    (value('rowSums') as List? ?? List.filled(h, 0))[row],
                    c['rowTotals'][row],
                  ),
              ],
            ),
          ),

        // Stacking support warning (if configured)
        if (c['support'] == true)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: style.color('border'),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: style.color('border')),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.layers_outlined,
                  size: 16,
                  color: style.color('warning'),
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label(
                      'Build from the floor up. Remove upper pieces before their supports.',
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: style.color('warning'),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Light goals (if configured)
        if (lights != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: style.color('primary'),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label('Light goal: '),
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                SizedBox(
                  width: 80,
                  height: 48,
                  child: CustomPaint(
                    painter: _TilePainter(
                      style,
                      c,
                      {},
                      phase,
                      lights['target'] as List,
                      null,
                      null,
                      false,
                      lightOnly: true,
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '${value('lightErrors') ?? 0} lights to match',
                  style: TextStyle(
                    color: style.color('warning'),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
      ];
      final board = selectionRegion(
        SizedBox(
          key: ValueKey('tile-placement-board'),
          width: w * cell,
          height: h * cell,
          child: MouseRegion(
            onHover: (e) => setState(
              () => hover = Position(
                (e.localPosition.dx / cell).floor() - grabOffset.x,
                (e.localPosition.dy / cell).floor() - grabOffset.y,
              ),
            ),
            onExit: (_) => setState(() => hover = null),
            child: DragTarget<String>(
              onWillAcceptWithDetails: (d) => widget.onAction != null,
              onAcceptWithDetails: (d) {
                if (hover != null) put(d.data, hover!);
              },
              onMove: (d) {
                final box =
                    boardKey.currentContext!.findRenderObject() as RenderBox;
                final p = box.globalToLocal(d.offset);
                setState(
                  () => hover = Position(
                    (p.dx / cell).floor(),
                    (p.dy / cell).floor(),
                  ),
                );
              },
              builder: (context, candidates, rejected) => GestureDetector(
                key: boardKey,
                onTapUp: widget.onAction == null
                    ? null
                    : (e) {
                        final p = Position(
                          (e.localPosition.dx / cell).floor(),
                          (e.localPosition.dy / cell).floor(),
                        );
                        final owner = placed.entries
                            .where(
                              (entry) => TilePlacementSystem.cells(
                                pieces.firstWhere((a) => a['id'] == entry.key),
                                entry.value as List,
                              ).contains(p),
                            )
                            .firstOrNull;
                        if (selected == null) {
                          if (owner != null) choose(owner.key as String, p);
                        } else {
                          put(
                            selected!,
                            Position(p.x - grabOffset.x, p.y - grabOffset.y),
                          );
                        }
                      },
                child: CustomPaint(
                  painter: _TilePainter(
                    style,
                    c,
                    placed,
                    phase,
                    value('lights') as List? ?? [],
                    selected,
                    hover,
                    true,
                    rotation: selected == null ? 0 : angle(selected!),
                    moved: moved,
                    transferSteps: value('transferSteps') as int? ?? 0,
                    removalsUsed: value('removalsUsed') as int? ?? 0,
                    activeVariant: selected == null ? 0 : form(selected!),
                  ),
                ),
              ),
            ),
          ),
        ),
        dismissOutside: true,
      );
      final cards = <Widget>[
        for (final piece in pieces)
          selectionRegion(
            Draggable<String>(
              data: piece['id'] as String,
              onDragEnd: (_) => cancelSelection(),
              onDragStarted: () => choose(piece['id'] as String),
              feedback: Material(
                color: Colors.transparent,
                child: _pieceCard(piece),
              ),
              child: InkWell(
                key: ValueKey('tile-piece-${piece['id']}'),
                borderRadius: BorderRadius.circular(16),
                onTap: () => choose(piece['id'] as String),
                child: _pieceCard(piece),
              ),
            ),
          ),
      ];
      final boardPanel = _surface(
        padding: wide ? 24 : 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  targets.length > 1
                      ? c['targetLabels'] != null
                            ? '${targetName(phase).toUpperCase()} / ${phase + 1} OF ${targets.length}'
                            : 'TARGET ${phase + 1} OF ${targets.length}'
                      : 'THE BOARD',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: style.color('muted'),
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('tile-view-target'),
                  onPressed: () => _showTargetPreviewDialog(context, phase),
                  style: TextButton.styleFrom(
                    foregroundColor: style.color('primary'),
                    minimumSize: Size(44, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: Icon(Icons.open_in_full_rounded, size: 13),
                  label: Text(
                    label('Target'),
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
                ValueListenableBuilder<Matrix4>(
                  valueListenable: _zoom,
                  builder: (context, transform, child) => TextButton(
                    onPressed: () => _zoom.value = Matrix4.identity(),
                    style: TextButton.styleFrom(
                      foregroundColor: style.color('muted'),
                      minimumSize: Size(44, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: Text(
                      '${(transform.getMaxScaleOnAxis() * 100).round()}%',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  '$filled / $total',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: style.color('text'),
                  ),
                ),
              ],
            ),
            if (limits != null) ...[
              SizedBox(height: 8),
              Text(
                'Moves ${value('movesUsed') ?? 0}/${limits['moves']}  |  Rotations ${value('rotationsUsed') ?? 0}/${limits['rotations']}',
                key: ValueKey('tile-action-budget'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: style.color('primary'),
                ),
              ),
            ],
            if (c['allowUnused'] == true) ...[
              SizedBox(height: 5),
              Text(
                label('Some pieces may stay in the tray. Choose your pieces.'),
                style: TextStyle(fontSize: 10, color: style.color('muted')),
                textAlign: TextAlign.center,
              ),
            ],
            if (mixed) ...[
              SizedBox(height: 8),
              Text(
                permanent
                    ? 'Permanent bonds | Shape choices: ${pieces.where((p) => p['variants'] != null).length}'
                    : 'Group moved: ${value('linkMoved') == 1 ? 'yes' : 'no'} | Released: ${value('linkReleased') == 1 ? 'yes' : 'no'} | Shape choices: ${pieces.where((p) => p['variants'] != null).length}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: style.color('primary')),
              ),
            ],
            if (c['echoLinks'] != null) ...[
              SizedBox(height: 10),
              _statusText(
                echoPartner == null
                    ? selected != null &&
                              configuredEchoPartner(selected!) != null
                          ? 'Echo ${configuredEchoPartner(selected!)!.toUpperCase()} activates once both partners are placed.'
                          : 'Echo pairs: same movement, opposite quarter-turns.'
                    : '${selected!.toUpperCase()} + ${echoPartner.toUpperCase()}: move together, turn oppositely.',
                key: ValueKey('tile-echo-status'),
              ),
            ],
            if (c['linkedMovement'] != null && !mixed) ...[
              SizedBox(height: 12),
              _statusText(magneticStatus(), key: ValueKey('tile-link-status')),
              if (!permanent)
                Text(
                  'Chain moved: ${value('linkMoved') == 1 ? 'yes' : 'no'} | Released: ${value('linkReleased') == 1 ? 'yes' : 'no'}',
                  style: TextStyle(fontSize: 10, color: style.color('muted')),
                ),
            ],
            if (c['variantCells'] != null && !mixed) ...[
              SizedBox(height: 12),
              _statusText(
                pieces.any((p) => p.containsKey('requiredVariant'))
                    ? 'Workshop changes: ${value('formErrors') ?? 0} pieces still need their required form'
                    : 'Either form is allowed. Choose the shapes that fit.',
                key: ValueKey('tile-form-status'),
              ),
            ],
            if (c['neighborCounts'] != null) ...[
              SizedBox(height: 8),
              _statusText(
                label(
                  'CONTACT WEB: exact neighbours on each card. Rivals must not share a side.',
                ),
                key: ValueKey('tile-contact-status'),
              ),
              if (selected != null)
                Text(
                  '${selected!.toUpperCase()}: ${(c['neighborCounts'] as Map).containsKey(selected) ? 'touch ${(c['neighborCounts'] as Map)[selected]} different pieces' : 'no neighbour quota'}. Keep apart: ${(c['forbiddenContacts'] as List? ?? []).where((pair) => (pair as List).contains(selected)).map((pair) => (pair as List).firstWhere((id) => id != selected).toString().toUpperCase()).join(', ')}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: style.color('text')),
                ),
            ],
            if (c['rotationLinks'] != null) ...[
              SizedBox(height: 12),
              _statusText(
                selected == null
                    ? 'Paired pieces turn together, wherever they are.'
                    : 'Rotate ${TilePlacementSystem.rotationGroup(c, selected!).map((s) => s.toUpperCase()).join(' + ')} together',
                key: ValueKey('tile-pair-status'),
              ),
              Text(
                'Pair turned on board: ${value('pairedTurned') == 1 ? 'yes' : 'no'}',
                style: TextStyle(fontSize: 10, color: style.color('muted')),
              ),
            ],
            if (c['freeSpace'] == true) ...[
              SizedBox(height: 12),
              _statusText(
                label('Keep one connected region of empty play cells.'),
                key: ValueKey('tile-space-status'),
              ),
            ],
            if (insertion != null) ...[
              SizedBox(height: 12),
              _statusText(
                selected == null
                    ? 'Entry arrows mark a board side. Plan the placement order.'
                    : '${selected!.toUpperCase()}: enter from the ${['top', 'right', 'bottom', 'left'][pieces.firstWhere((p) => p['id'] == selected)['entrySide'] as int]} edge',
                key: ValueKey('tile-insertion-status'),
              ),
            ],
            if (crossSums) ...[
              SizedBox(height: 12),
              _statusText(
                label('Match every row and column: current / target'),
              ),
            ],
            if (transfer != null) ...[
              SizedBox(height: 10),
              Text(
                phase == 0
                    ? 'Target 2: ${transfer['maxSteps']} steps | ${transfer['maxRemovals']} tray return'
                    : 'Steps ${value('transferSteps') ?? 0}/${transfer['maxSteps']} | Returns ${value('removalsUsed') ?? 0}/${transfer['maxRemovals']} | Tray ${(value('transferRoster') as List? ?? pieces.map((p) => p['id']).toList()).where((id) => !placed.containsKey(id)).length}/${transfer['trayCapacity']}',
                key: ValueKey('tile-transfer-status'),
                style: TextStyle(
                  fontSize: 11,
                  color: style.color('primary'),
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (targets.length > 1) ...[
              SizedBox(height: mixed ? 10 : 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < targets.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: InkWell(
                        key: ValueKey('tile-target-preview-$i'),
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _showTargetPreviewDialog(context, i),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: mixed ? 8 : 10,
                          ),
                          decoration: BoxDecoration(
                            color: i == phase
                                ? style.color('primarySoft')
                                : style.color('primarySoft'),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: i == phase
                                  ? style.color('primarySoft')
                                  : style.color('primarySoft'),
                            ),
                          ),
                          child: Column(
                            children: [
                              SizedBox(
                                width: 116,
                                height: mixed || c['silhouetteMode'] == true
                                    ? 60
                                    : 80,
                                child: CustomPaint(
                                  painter: _TilePainter(
                                    style,
                                    c,
                                    {},
                                    i,
                                    const [],
                                    null,
                                    null,
                                    false,
                                  ),
                                ),
                              ),
                              SizedBox(height: 6),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    targetName(i),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: i == phase
                                          ? style.color('primary')
                                          : style.color('muted'),
                                    ),
                                  ),
                                  SizedBox(width: 4),
                                  Icon(
                                    Icons.open_in_full_rounded,
                                    size: 11,
                                    color: i == phase
                                        ? style.color('primary')
                                        : style.color('muted'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if ((transfer != null && phase > 0) ||
                insertion != null ||
                c['playArea'] != null) ...[
              SizedBox(height: 10),
              Text(
                label('Outlined: destination | Pale: transit | Grey: blocked'),
                style: TextStyle(fontSize: 10, color: style.color('muted')),
                textAlign: TextAlign.center,
              ),
            ],
            SizedBox(height: wide ? 20 : 14),
            Center(
              child: SizedBox(
                key: ValueKey('tile-board-viewport'),
                width: w * cell + (crossSums ? 44 : 0),
                height: h * cell + (crossSums ? 30 : 0),
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: .7,
                  maxScale: 3.5,
                  boundaryMargin: const EdgeInsets.all(160),
                  child: crossSums
                      ? Stack(
                          children: [
                            Positioned(
                              left: 44,
                              top: 30,
                              width: w * cell,
                              height: h * cell,
                              child: board,
                            ),
                            for (var col = 0; col < w; col++)
                              Positioned(
                                left: 44 + col * cell,
                                top: 0,
                                width: cell,
                                height: 30,
                                child: Center(
                                  child: Text(
                                    '${(value('columnSums') as List? ?? List.filled(w, 0))[col]}/${c['columnTotals'][col]}',
                                    key: ValueKey('tile-column-$col'),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: style.color('primary'),
                                    ),
                                  ),
                                ),
                              ),
                            for (var row = 0; row < h; row++)
                              Positioned(
                                left: 0,
                                top: 30 + row * cell,
                                width: 40,
                                height: cell,
                                child: Center(
                                  child: Text(
                                    '${(value('rowSums') as List? ?? List.filled(h, 0))[row]}/${c['rowTotals'][row]}',
                                    key: ValueKey('tile-row-$row'),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: style.color('primary'),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        )
                      : board,
                ),
              ),
            ),
            SizedBox(height: wide ? 20 : 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : filled / total,
                minHeight: 3,
                color: style.color('primary'),
                backgroundColor: style.color('primarySoft'),
              ),
            ),
            if (pieces.any((p) => p['edges'] != null)) ...[
              SizedBox(height: 12),
              Text(
                '${value('edgeErrors') ?? 0} open connections',
                style: TextStyle(fontSize: 11, color: style.color('muted')),
              ),
            ],
          ],
        ),
      );
      final cardGrid = Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: cards,
      );
      final trayPanel = _surface(
        padding: wide ? 20 : 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  label('Your pieces'),
                  style: TextStyle(
                    fontSize: 19,
                    letterSpacing: -.4,
                    fontWeight: FontWeight.w700,
                    color: style.color('primary'),
                  ),
                ),
                Text(
                  '${pieces.length} shapes',
                  style: TextStyle(fontSize: 11, color: style.color('muted')),
                ),
              ],
            ),
            SizedBox(height: 20),
            if (wide)
              if (pieces.length > 12)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: min(
                        440.0,
                        max(240.0, constraints.maxHeight - 240),
                      ),
                      child: SingleChildScrollView(
                        key: ValueKey('tile-piece-list'),
                        child: cardGrid,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Scroll to see all ${pieces.length} pieces',
                      style: TextStyle(
                        fontSize: 10,
                        color: style.color('muted'),
                      ),
                    ),
                  ],
                )
              else
                cardGrid
            else
              SizedBox(
                height: 126,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < cards.length; i++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: i == cards.length - 1 ? 0 : 8,
                          ),
                          child: cards[i],
                        ),
                    ],
                  ),
                ),
              ),
            if (selectedPiece?['variants'] != null) ...[
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (
                    var i = 0;
                    i < (selectedPiece!['variants'] as List).length;
                    i++
                  )
                    SizedBox(
                      width: 85,
                      height: 80,
                      child: _variantPreview(
                        selectedPiece,
                        i,
                        angle(selected!),
                      ),
                    ),
                ],
              ),
            ],
            SizedBox(height: 18),
            selectionRegion(
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: style.color('surface'),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: style.color('surfaceAlt')),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 4,
                  children: [
                    _pieceControl(
                      id: 'rotate',
                      label:
                          'Rotate${selected == null ? '' : ' (${angle(selected!) * 90}?)'}',
                      icon: Icons.rotate_right_rounded,
                      styled:
                          selected != null && !rotationBlocked && !noRotations,
                      onPressed:
                          selected == null ||
                              rotationBlocked ||
                              noRotations ||
                              widget.onAction == null
                          ? null
                          : rotateSelected,
                      foreground: style.color('primary'),
                      background: style.color('primarySoft'),
                    ),
                    _pieceControl(
                      id: 'remove',
                      label: label('Return'),
                      icon: Icons.undo_rounded,
                      styled:
                          selected != null &&
                          !bonded &&
                          placed.containsKey(selected) &&
                          widget.onAction != null,
                      onPressed:
                          selected == null ||
                              bonded ||
                              !placed.containsKey(selected) ||
                              widget.onAction == null
                          ? null
                          : returnSelected,
                      foreground: style.color('text'),
                      background: style.color('primarySoft'),
                    ),
                    if (c['echoSwap'] == true)
                      TextButton.icon(
                        key: ValueKey('tile-echo-swap'),
                        onPressed:
                            echoPartner == null ||
                                widget.onAction == null ||
                                (limits != null &&
                                    (value('movesUsed') as int? ?? 0) >=
                                        (limits['moves'] as int))
                            ? null
                            : swapSelected,
                        icon: Icon(Icons.swap_horiz_rounded, size: 18),
                        label: Text(label('Swap positions')),
                      ),
                    if (c['variantCells'] != null)
                      TextButton.icon(
                        key: ValueKey('tile-change'),
                        onPressed: canChange && widget.onAction != null
                            ? changeSelected
                            : null,
                        icon: Icon(Icons.swap_horiz_rounded, size: 18),
                        label: Text(
                          label('Change form'),
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.black54,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: widget.onReset,
                      child: Text(
                        label('Reset'),
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 12),
            Text(
              selected == null
                  ? 'Select a piece, then tap the board.'
                  : bonded && !rotationBlocked
                  ? echoPartner != null
                        ? 'Echo ${echoPartner.toUpperCase()} follows this move and turns the other way.'
                        : 'Permanent bond: move or rotate the whole cluster. Undo to revise.'
                  : rotationBlocked
                  ? 'Slide ${selected!.toUpperCase()}, or Return it to rotate.'
                  : 'Rotate or place piece ${selected!.toUpperCase()}.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: style.color('muted'),
              ),
            ),
            if (phase + 1 < targets.length) ...[
              SizedBox(height: 16),
              FilledButton.icon(
                key: ValueKey('tile-next-target'),
                onPressed: value('fit') == 1 && widget.onAction != null
                    ? () => widget.onAction!(
                        GameAction(c['nextAction'] as String? ?? 'next_target'),
                      )
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: style.color('primary'),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: Icon(Icons.arrow_forward_rounded, size: 17),
                label: Text(
                  c['targetLabels'] == null
                      ? 'Continue to shape 2'
                      : 'Build ${targetName(phase + 1)}',
                ),
              ),
            ],
          ],
        ),
      );
      return SingleChildScrollView(
        child: Center(
          child: SizedBox(
            width: contentWidth,
            child: Column(
              children: [
                ...extras,
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: boardPanel),
                      SizedBox(width: 24),
                      SizedBox(width: 340, child: trayPanel),
                    ],
                  )
                else ...[
                  boardPanel,
                  SizedBox(height: 16),
                  trayPanel,
                ],
                SizedBox(height: 20),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _pieceControl({
    required String id,
    required String label,
    required IconData icon,
    required bool styled,
    required VoidCallback? onPressed,
    required Color foreground,
    required Color background,
  }) => TextButton.icon(
    key: ValueKey('tile-$id'),
    style: TextButton.styleFrom(
      foregroundColor: styled ? foreground : Colors.black38,
      backgroundColor: styled ? background : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(
      label,
      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
    ),
  );

  Widget _rowChip(int row, dynamic current, dynamic target) {
    final matches = current == target;
    return Chip(
      avatar: Icon(
        matches ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 16,
        color: matches ? style.color('text') : Colors.black45,
      ),
      label: Text(
        'Row ${row + 1}: $current / $target',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      backgroundColor: matches
          ? style.color('primarySoft')
          : style.color('surfaceAlt'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: matches
              ? style.color('primarySoft')
              : style.color('surfaceAlt'),
        ),
      ),
    );
  }

  Widget _statusText(String text, {Key? key}) => Text(
    text,
    key: key,
    textAlign: TextAlign.center,
    style: TextStyle(fontSize: 11, color: style.color('primary')),
  );

  Widget _surface({required Widget child, double padding = 20}) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: style.color('primarySoft')),
      boxShadow: [
        BoxShadow(
          color: style.color('primary').withValues(alpha: .035),
          blurRadius: 30,
          offset: Offset(0, 10),
        ),
      ],
    ),
    child: child,
  );

  final boardKey = GlobalKey();

  Widget _pieceArtwork(Map<String, dynamic> piece, List pose, double extent) {
    final cells = TilePlacementSystem.cells(piece, pose);
    final w = cells.map((p) => p.x).reduce(max) + 1;
    final h = cells.map((p) => p.y).reduce(max) + 1;
    final unit = min(extent / w, extent / h);
    return SizedBox(
      width: w * unit,
      height: h * unit,
      child: CustomPaint(
        painter: _TilePainter(
          style,
          {
            'pieces': [piece],
            'targets': const [[]],
            'size': [w, h],
          },
          {piece['id']: pose},
          0,
          const [],
          null,
          null,
          false,
          isThumbnail: true,
        ),
      ),
    );
  }

  Widget _variantPreview(Map<String, dynamic> p, int variant, int rotation) =>
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Form ${String.fromCharCode(65 + variant)}',
            style: TextStyle(fontSize: 10, color: style.color('muted')),
          ),
          SizedBox(height: 5),
          _pieceArtwork(p, [0, 0, rotation, variant], 45),
        ],
      );

  Widget _pieceCard(Map<String, dynamic> p) {
    final id = p['id'] as String, r = angle(id);
    final activeMembers = selected == null
        ? <String>{}
        : {
            ...TilePlacementSystem.linkedGroup(c, placed, selected!),
            if (c['rotationLinks'] != null)
              ...TilePlacementSystem.rotationGroup(c, selected!),
          };
    final color = _tileColor(p['color']), active = activeMembers.contains(id);
    final rotationPartners = c['rotationLinks'] == null
        ? <String>[]
        : TilePlacementSystem.rotationGroup(
            c,
            id,
          ).where((s) => s != id).toList();
    final onBoard = placed.containsKey(id);
    return AnimatedContainer(
      duration: Duration(milliseconds: 140),
      width: 92,
      height: 124,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: .07)
            : onBoard
            ? style.color('primarySoft')
            : style.color('primarySoft'),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: active
              ? color.withValues(alpha: .9)
              : style.color('primarySoft'),
          width: active ? 1.6 : 1,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: color.withValues(alpha: .12),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
              ]
            : [],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                id.toUpperCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: style.color('text'),
                ),
              ),
              Spacer(),
              Text(
                '${r * 90}\u00b0',
                style: TextStyle(fontSize: 9, color: style.color('muted')),
              ),
            ],
          ),
          Expanded(
            child: Center(
              child: _pieceArtwork(p, [
                0,
                0,
                r,
                if (p['variants'] != null) form(id),
              ], 70),
            ),
          ),
          if (p['edges'] != null)
            Text(
              (p['edges'] as List)
                  .map(
                    (e) =>
                        '${e['symbol']}${['\u2191', '\u2192', '\u2193', '\u2190'][((e['direction'] as int) + r) % 4]}',
                  )
                  .join(' '),
              maxLines: 2,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: style.color('primary'),
              ),
              textAlign: TextAlign.center,
            ),
          if ((c['neighborCounts'] as Map? ?? {}).containsKey(id))
            Text(
              'Touch ${(c['neighborCounts'] as Map)[id]} pieces',
              style: TextStyle(fontSize: 10, color: style.color('primary')),
            ),
          if (configuredEchoPartner(id) != null)
            Text(
              'Echo ${configuredEchoPartner(id)!.toUpperCase()}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: style.color('primary'),
              ),
            ),
          if (rotationPartners.isNotEmpty)
            Text(
              'Turns ${rotationPartners.map((s) => s.toUpperCase()).join('+')}',
              style: TextStyle(fontSize: 10, color: style.color('primary')),
            ),
          if (p['variants'] != null)
            Text(
              'Form ${String.fromCharCode(65 + form(id))}',
              style: TextStyle(fontSize: 10, color: style.color('primary')),
            ),
          if (p['entrySide'] != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  [
                    Icons.south_rounded,
                    Icons.west_rounded,
                    Icons.north_rounded,
                    Icons.east_rounded,
                  ][p['entrySide'] as int],
                  size: 14,
                  color: style.color('primary'),
                ),
                SizedBox(width: 3),
                Text(
                  ['Top', 'Right', 'Bottom', 'Left'][p['entrySide'] as int],
                  style: TextStyle(fontSize: 10, color: style.color('muted')),
                ),
              ],
            ),
          if (p['value'] != null)
            Text(
              '${p['value']} per cell',
              style: TextStyle(fontSize: 10, color: style.color('muted')),
            ),
        ],
      ),
    );
  }
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
