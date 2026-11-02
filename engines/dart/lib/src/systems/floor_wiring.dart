/// Electrical port groups; the two wires in a crossing remain separate.
const floorGroups = <String, List<String>>{
  'cross': ['NS', 'EW'],
  'ne': ['NE', 'SW'],
  'nw': ['NW', 'SE'],
  'junction': ['NESW'],
  'h': ['EW'],
  'v': ['NS'],
};

Map<String, List<String>> floorSources(Map floor) {
  const dirs = {
    'N': (0, -1, 'S'),
    'E': (1, 0, 'W'),
    'S': (0, 1, 'N'),
    'W': (-1, 0, 'E')
  };
  final tiles = {
    for (final t in floor['tiles'])
      (t['x'] as int, t['y'] as int): t['shape'] as String
  };
  final terminals = {
    for (final t in floor['terminals'])
      (t['x'] as int, t['y'] as int, t['side'] as String): t
  };
  final result = <String, List<String>>{};
  for (final t in floor['terminals']) {
    if (t['kind'] != 'sink') continue;
    final stack = <(int, int, String)>[(t['x'], t['y'], t['side'])];
    final seen = <(int, int, String)>{};
    final sources = <String>{};
    while (stack.isNotEmpty) {
      final at = stack.removeLast();
      if (!seen.add(at)) continue;
      final (x, y, side) = at;
      final term = terminals[at];
      if (term != null && term['kind'] == 'source')
        sources.add(term['id'] as String);
      for (final group in floorGroups[tiles[(x, y)]]!) {
        if (!group.contains(side)) continue;
        for (final port in group.split('')) {
          if (!seen.contains((x, y, port))) stack.add((x, y, port));
          final (dx, dy, other) = dirs[port]!;
          if (tiles.containsKey((x + dx, y + dy)))
            stack.add((x + dx, y + dy, other));
        }
      }
    }
    result[t['id']] = sources.toList()..sort();
  }
  return result;
}

/// A node's private counter is separate from its visible output bit.
int nodeStep(String op, List<int> args, int old, Map counters, String id) {
  if (op.startsWith('counter')) {
    final period = int.parse(op.substring(7));
    final count = ((counters[id] as int? ?? 0) + args[0]) % period;
    counters[id] = count;
    return args[0] == 1 && count == 0 ? 1 : 0;
  }
  return switch (op) {
    'copy' => args[0],
    'not' => 1 - args[0],
    'toggle' => old ^ args[0],
    'and' => args[0] & args[1],
    'or' => args[0] | args[1],
    'xor' => args[0] ^ args[1],
    'latch' => args[1] == 1 ? 0 : (args[0] == 1 ? 1 : old),
    _ => throw ArgumentError('Unknown node op'),
  };
}
