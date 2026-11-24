import '../models/position.dart';

/// Optional constraints, independent of the placement geometry implementation.
List<String> unsupportedTiles(Map<Position, String> occupied, int floorY) {
  // A downward contact supports a whole rigid piece, including overhangs.
  // Only paths rooted at the floor count; unsupported cycles cannot self-support.
  var grounded = {
    for (final e in occupied.entries)
      if (e.key.y == floorY) e.value
  };
  while (true) {
    final supported = {
      ...grounded,
      for (final e in occupied.entries)
        if (grounded.contains(occupied[e.key + const Position(0, 1)])) e.value
    };
    if (supported.length == grounded.length) {
      return occupied.values.toSet().difference(grounded).toList()..sort();
    }
    grounded = supported;
  }
}

List<int> rowSums(Map<String, dynamic> config, Map<Position, String> occupied) {
  final values = {
    for (final p in config['pieces'] as List) p['id']: p['value'] as int? ?? 0
  };
  final totals = List<int>.filled(config['size'][1] as int, 0);
  for (final e in occupied.entries) {
    totals[e.key.y] += values[e.value]!;
  }
  return totals;
}

List<int> columnSums(
    Map<String, dynamic> config, Map<Position, String> occupied) {
  final values = {
    for (final p in config['pieces'] as List) p['id']: p['value'] as int? ?? 0
  };
  final totals = List<int>.filled(config['size'][0] as int, 0);
  for (final e in occupied.entries) {
    totals[e.key.x] += values[e.value]!;
  }
  return totals;
}
