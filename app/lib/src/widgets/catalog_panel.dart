import 'package:flutter/material.dart';
import 'package:gridponder_engine/engine.dart';
import '../services/pack_service.dart';

Color? _parseHex(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final clean = hex.replaceAll('#', '').trim();
  if (clean.length == 6) {
    return Color(int.parse('FF$clean', radix: 16));
  } else if (clean.length == 8) {
    return Color(int.parse(clean, radix: 16));
  }
  return null;
}

/// A readable viewport for pack item illustrations with optional holding offset.
class CatalogIcon extends StatelessWidget {
  final PackService pack;
  final String? image;
  final double size;
  final bool held;
  final IconData fallbackIcon;

  const CatalogIcon({
    super.key,
    required this.pack,
    required this.image,
    this.size = 36,
    this.held = false,
    this.fallbackIcon = Icons.category_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final imgPath = image;
    return SizedBox.square(
      dimension: size,
      child: ClipRect(
        child: Transform.translate(
          offset: Offset(0, held ? -size * .38 : 0),
          child: Transform.scale(
            scale: held ? 2.2 : 1,
            child: imgPath != null && imgPath.isNotEmpty
                ? Image(
                    image: pack.resolvePackImage(imgPath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Icon(fallbackIcon, size: size * 0.7),
                  )
                : Icon(fallbackIcon, size: size * 0.7),
          ),
        ),
      ),
    );
  }
}

/// A catalogue layout panel displaying available conversions or product
/// definitions, required input sources, remaining variables, and counts of
/// concealed demands.
class CatalogBoardLayout extends StatefulWidget {
  final PackService pack;
  final LevelState state;
  final Widget board;

  const CatalogBoardLayout({
    super.key,
    required this.pack,
    required this.state,
    required this.board,
  });

  /// Validates catalog configuration defensively to avoid rendering crashes.
  static bool isValidCatalog(Map<String, dynamic>? config) {
    if (config == null) return false;
    final products = config['catalog'] is Map<String, dynamic>
        ? (config['catalog'] as Map<String, dynamic>)['products'] ??
            (config['catalog'] as Map<String, dynamic>)['recipes']
        : config['products'] ?? config['recipes'];
    final inputs = config['catalog'] is Map<String, dynamic>
        ? (config['catalog'] as Map<String, dynamic>)['inputs'] ??
            (config['catalog'] as Map<String, dynamic>)['ingredients']
        : config['inputs'] ?? config['ingredients'];

    if (products is! List || inputs is! Map) return false;
    for (final item in products) {
      if (item is! Map) return false;
      final itemInputs = item['inputs'] ?? item['ingredients'];
      if (itemInputs is! List) return false;
    }
    return true;
  }

  @override
  State<CatalogBoardLayout> createState() => _CatalogBoardLayoutState();
}


class _CatalogBoardLayoutState extends State<CatalogBoardLayout> {
  bool _guideVisible = true;

  PackService get pack => widget.pack;
  LevelState get state => widget.state;
  Widget get board => widget.board;

  Map<String, dynamic>? get _catalogConfig {
    final pres = pack.presentation;
    if (pres == null) return null;
    if (pres['catalog'] is Map<String, dynamic>) {
      return pres['catalog'] as Map<String, dynamic>;
    }
    return pres;
  }

  List<String> get _boardObjectKinds => [
        for (var y = 0; y < state.board.height; y++)
          for (var x = 0; x < state.board.width; x++)
            if (state.board.getEntity('objects', Position(x, y)) case final entity?)
              entity.kind,
      ];

  @override
  Widget build(BuildContext context) {
    final config = _catalogConfig;
    if (!CatalogBoardLayout.isValidCatalog(config)) return board;

    final palette = pack.theme?.palette;
    final colorScheme = Theme.of(context).colorScheme;

    // Theme palette colours with neutral fallbacks
    final panelBg = _parseHex(palette?['catalogBackground']) ??
        _parseHex(config?['panelColor'] as String?) ??
        colorScheme.surfaceContainerHighest.withValues(alpha: 0.65);
    final cardBg = _parseHex(palette?['catalogCard']) ??
        _parseHex(config?['cardColor'] as String?) ??
        colorScheme.surface;
    final ink = _parseHex(palette?['catalogText']) ??
        _parseHex(config?['textColor'] as String?) ??
        colorScheme.onSurface;
    final muted = _parseHex(palette?['catalogMuted']) ??
        _parseHex(config?['mutedColor'] as String?) ??
        colorScheme.onSurfaceVariant;
    final borderCol = _parseHex(palette?['catalogBorder']) ??
        _parseHex(config?['borderColor'] as String?) ??
        colorScheme.outlineVariant;

    final labels = config!['labels'] as Map<String, dynamic>? ?? const {};
    String label(String key, String fallback) =>
        labels[key] as String? ?? fallback;
    String counted(String key, String fallback, int count, String noun) =>
        label(key, fallback)
            .replaceAll('{count}', '$count')
            .replaceAll('{noun}', noun);

    if (!_guideVisible) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.view_list_outlined, size: 18),
              label: Text(label('showGuide', 'Show catalog')),
              onPressed: () => setState(() => _guideVisible = true),
            ),
          ),
          Expanded(child: board),
        ],
      );
    }

    final rawInputs = (config['inputs'] ?? config['ingredients']) as Map;
    final inputs = rawInputs.cast<String, dynamic>();

    final concealedKinds = List<String>.from(
      config['concealedDemandKinds'] ?? config['hiddenOrderKinds'] ?? [],
    );
    final objects = _boardObjectKinds;
    final concealedCount = objects.where(concealedKinds.contains).length;

    final rawProducts = (config['products'] ?? config['recipes']) as List;
    final products = rawProducts
        .whereType<Map>()
        .map((p) => p.cast<String, dynamic>())
        .where((p) {
          final reqInputs = List<String>.from(p['inputs'] ?? p['ingredients'] ?? []);
          return reqInputs.every((i) {
            final inDef = inputs[i];
            if (inDef is! Map) return false;
            final srcKind = inDef['sourceKind'] ?? inDef['stationKind'];
            return srcKind == null || objects.contains(srcKind);
          });
        })
        .where((p) {
          final targetKind = p['demandKind'] ?? p['orderKind'];
          return concealedCount > 0 || state.isWon || (targetKind != null && objects.contains(targetKind));
        })
        .toList();

    final remainingVar = config['remainingVariable'] ?? 'remaining';
    final remainingCount = state.variables[remainingVar] ?? 0;

    final demandNoun = label(
      concealedCount == 1 ? 'demandSingular' : 'demandPlural',
      concealedCount == 1 ? 'demand' : 'demands',
    );
    final remainingNoun = label(
      remainingCount == 1 ? 'remainingSingular' : 'remainingPlural',
      remainingCount == 1 ? 'remaining' : 'remaining',
    );

    final concealedHint = counted(
      'concealedHint',
      label('hiddenHint', 'Concealed: {count} {noun}'),
      concealedCount,
      demandNoun,
    );
    final remainingText = counted(
      'remaining',
      'Remaining: {count} {noun}',
      remainingCount,
      remainingNoun,
    );
    final compactRemaining = counted(
      'compactRemaining',
      '{count} left',
      remainingCount,
      '',
    );
    final completed = label('completed', 'Completed');

    final heldItem = state.avatar.inventory.slot;
    final heldName = heldItem == null
        ? label('emptySlot', label('emptyHands', 'None'))
        : (pack.game.entityKinds[heldItem]?.uiName ?? heldItem);
    final activeText = label('activeItem', label('carrying', 'Active: {item}'))
        .replaceAll('{item}', heldName);

    Widget header({bool compact = false}) {
      final summary = remainingCount == 0
          ? completed
          : (compact ? compactRemaining : remainingText);
      if (compact) {
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label('title', 'Catalog'),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        summary,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: remainingCount == 0 ? Colors.green.shade700 : muted,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      activeText,
                      style: TextStyle(fontSize: 11, color: muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: label('hideGuide', 'Hide guide'),
              icon: const Icon(Icons.close, size: 18),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => setState(() => _guideVisible = false),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label('title', 'Catalog'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: label('hideGuide', 'Hide guide'),
                icon: const Icon(Icons.close, size: 18),
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => setState(() => _guideVisible = false),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              activeText,
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderCol, width: 0.8),
            ),
            child: Text(
              summary,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: remainingCount == 0 ? Colors.green.shade700 : ink,
              ),
            ),
          ),
          if (concealedCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                concealedHint,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
        ],
      );
    }

    Widget productCard(Map<String, dynamic> prod, {bool compact = false}) {
      final reqInputKeys = List<String>.from(prod['inputs'] ?? prod['ingredients'] ?? []);
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 12,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderCol, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var idx = 0; idx < reqInputKeys.length; idx++) ...[
                  if (idx > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text('+', style: TextStyle(color: muted, fontSize: 16)),
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        CatalogIcon(
                          pack: pack,
                          image: inputs[reqInputKeys[idx]]?['image'] as String?,
                          size: compact ? 26 : 32,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          inputs[reqInputKeys[idx]]?['name'] as String? ?? reqInputKeys[idx],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: ink),
                        ),
                        if (!compact && inputs[reqInputKeys[idx]]?['stock'] is String)
                          Text(
                            label('stock', '{count} left').replaceAll(
                              '{count}',
                              '${state.variables[inputs[reqInputKeys[idx]]['stock']] ?? 0}',
                            ),
                            maxLines: 1,
                            style: TextStyle(fontSize: 10, color: muted),
                          ),
                      ],
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward_rounded, size: 16, color: muted),
                ),
                Expanded(
                  child: Column(
                    children: [
                      CatalogIcon(
                        pack: pack,
                        image: prod['image'] as String?,
                        held: true,
                        size: compact ? 28 : 36,
                      ),
                      Text(
                        prod['name'] as String? ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 880 ||
            (constraints.maxWidth >= 600 &&
                constraints.maxWidth > constraints.maxHeight * 1.4);

        final panelContent = Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: panelBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderCol, width: 0.8),
          ),
          child: wide
              ? SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      header(),
                      const SizedBox(height: 12),
                      for (final prod in products) ...[
                        productCard(prod),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header(compact: true),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: products.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, index) => SizedBox(
                          width: 230,
                          child: productCard(products[index], compact: true),
                        ),
                      ),
                    ),
                  ],
                ),
        );

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: board),
              const SizedBox(width: 14),
              SizedBox(
                width: (constraints.maxWidth * .32).clamp(240.0, 310.0),
                child: panelContent,
              ),
            ],
          );
        }

        // On narrow / vertical viewports, limit panel to a reasonable fraction
        // of screen height so the puzzle board and controls are not cramped.
        return Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (constraints.maxHeight * 0.32).clamp(80.0, 160.0),
              ),
              child: SingleChildScrollView(child: panelContent),
            ),
            const SizedBox(height: 8),
            Expanded(child: board),
          ],
        );
      },
    );
  }
}
