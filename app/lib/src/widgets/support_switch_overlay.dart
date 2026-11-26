part of 'board_renderer.dart';

typedef _SwitchPlate = ({
  String layer,
  Object? channel,
  String sprite,
  bool pressed,
});

class _SupportSwitches {
  final Map<Position, _SwitchPlate> plates;
  final Map<Object?, List<Position>> targets;

  const _SupportSwitches(this.plates, this.targets);

  factory _SupportSwitches.fromBoard(Board board, GameDefinition game) {
    for (final system in game.systems) {
      if (!system.enabled || system.type != 'support_collapse') continue;
      final config = system.config;
      final switches = config['switches'];
      if (switches is! Map) continue;

      final structure = config['layer'] as String? ?? 'ground';
      final plateLayer = switches['plateLayer'] as String? ?? structure;
      final targetLayer = switches['switchLayer'] as String? ?? structure;
      final plates = board.layers[plateLayer];
      final targets = board.layers[targetLayer];
      if (plates == null || targets == null) continue;

      final channelParam = switches['channelParam'] as String? ?? 'channel';
      final plateTags = _switchStrings(switches['plateTags'], ['plate']);
      final pressLayers = _switchStrings(switches['pressLayers'], [structure]);
      final pressTags = _switchStrings(switches['pressTags'], ['solid']);
      final plateViews = <Position, _SwitchPlate>{};

      for (final MapEntry(key: pos, value: plate) in plates.entries()) {
        final kind = game.entityKinds[plate.kind];
        final pressedSprite = kind?.display?['pressedSprite'];
        if (kind == null ||
            pressedSprite is! String ||
            !plateTags.any(kind.hasTag)) {
          continue;
        }
        final releasedSprite = resolveEntitySpritePath(kind, plate);
        if (releasedSprite == null) continue;

        // Use the visible board, so a passing piece lights the plate only
        // when it has finished moving and actually occupies this cell.
        final pressed = pressLayers.any((layer) {
          final occupant = board.getEntity(layer, pos);
          return occupant != null &&
              pressTags.any((tag) => game.hasTag(occupant.kind, tag));
        });
        plateViews[pos] = (
          layer: plateLayer,
          channel: plate.param(channelParam),
          sprite: pressed
              ? _fillSpriteParams(pressedSprite, plate)
              : releasedSprite,
          pressed: pressed,
        );
      }
      if (plateViews.isEmpty) continue;

      final transforms = switches['pressed'] as Map? ?? const {};
      final targetKinds = {...transforms.keys, ...transforms.values};
      final byChannel = <Object?, List<Position>>{};
      for (final MapEntry(key: pos, value: target) in targets.entries()) {
        if (targetKinds.contains(target.kind)) {
          (byChannel[target.param(channelParam)] ??= []).add(pos);
        }
      }
      return _SupportSwitches(plateViews, byChannel);
    }

    return const _SupportSwitches({}, {});
  }

  static List<String> _switchStrings(Object? value, List<String> fallback) =>
      value is List ? value.map((item) => item.toString()).toList() : fallback;
}

class _SupportSwitchOverlay extends StatefulWidget {
  final _SupportSwitches switches;
  final double cellSize;
  final int actionCount;
  final PackService packService;

  const _SupportSwitchOverlay({
    required this.switches,
    required this.cellSize,
    required this.actionCount,
    required this.packService,
  });

  @override
  State<_SupportSwitchOverlay> createState() => _SupportSwitchOverlayState();
}

typedef _SwitchPulse = ({Position source, Position target, Color color});

class _SupportSwitchOverlayState extends State<_SupportSwitchOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  List<_SwitchPulse> _pulses = const [];

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
  }

  @override
  void didUpdateWidget(covariant _SupportSwitchOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.actionCount == 0 ||
        widget.actionCount < oldWidget.actionCount ||
        widget.packService != oldWidget.packService) {
      _animation.reset();
      _pulses = const [];
      return;
    }

    final switches = widget.switches;
    final palette = widget.packService.theme?.palette;
    final pulses = <_SwitchPulse>[];
    for (final MapEntry(key: pos, value: plate) in switches.plates.entries) {
      final previous = oldWidget.switches.plates[pos];
      if (previous == null ||
          previous.channel != plate.channel ||
          previous.pressed == plate.pressed) {
        continue;
      }
      final color = cellNamedColor(
        'channel_${plate.channel}',
        palette: palette,
      );
      for (final target
          in switches.targets[plate.channel] ?? const <Position>[]) {
        if (target != pos)
          pulses.add((source: pos, target: target, color: color));
      }
    }
    if (pulses.isNotEmpty) {
      _pulses = pulses;
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cellSize = widget.cellSize;
    final pack = widget.packService;
    return Stack(
      children: [
        if (_pulses.isNotEmpty)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SwitchPulsePainter(_pulses, cellSize, _animation),
              ),
            ),
          ),
        for (final MapEntry(key: pos, value: plate)
            in widget.switches.plates.entries)
          Positioned(
            left: pos.x * cellSize,
            top: pos.y * cellSize,
            width: cellSize,
            height: cellSize,
            child: Image(
              image: pack.resolvePackImage(plate.sprite),
              fit: BoxFit.cover,
              semanticLabel:
                  'Channel ${plate.channel} plate, '
                  '${plate.pressed ? 'pressed' : 'released'}',
              errorBuilder: (_, __, ___) => Image.asset(
                pack.resolveSprite(plate.sprite),
                fit: BoxFit.cover,
              ),
            ),
          ),
      ],
    );
  }
}

class _SwitchPulsePainter extends CustomPainter {
  final List<_SwitchPulse> pulses;
  final double cellSize;
  final Animation<double> animation;

  _SwitchPulsePainter(this.pulses, this.cellSize, this.animation)
    : super(repaint: animation);

  Offset _center(Position pos) =>
      Offset((pos.x + 0.5) * cellSize, (pos.y + 0.5) * cellSize);

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    if (progress == 1) return;
    final fade = 1 - progress;
    final paint = Paint()..strokeWidth = max(1.0, cellSize * 0.035);
    for (final pulse in pulses) {
      final source = _center(pulse.source);
      final target = _center(pulse.target);
      paint.color = pulse.color.withValues(alpha: 0.42 * fade);
      canvas.drawLine(source, target, paint);
      paint.color = pulse.color.withValues(alpha: min(1.0, 2 * fade));
      canvas.drawCircle(
        Offset.lerp(source, target, Curves.easeOut.transform(progress))!,
        max(2.0, cellSize * 0.075),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SwitchPulsePainter oldDelegate) =>
      oldDelegate.pulses != pulses ||
      oldDelegate.cellSize != cellSize ||
      oldDelegate.animation != animation;
}
