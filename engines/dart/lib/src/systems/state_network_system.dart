import 'floor_wiring.dart';
import '../engine/game_system.dart';
import '../models/entity.dart';
import '../models/event.dart';
import '../models/game_action.dart';
import '../models/game_definition.dart';
import '../models/game_state.dart';
import '../models/position.dart';

/// Synchronous transitions with an explicit public observation projection.
/// Configuration and namespaced runtime variables are trusted engine data.
class StateNetworkSystem extends GameSystem {
  final Map<String, dynamic> config;
  StateNetworkSystem({required super.id, required this.config})
      : super(type: 'state_network') {
    _validate();
  }

  void _validate() {
    Never invalid() =>
        throw ArgumentError('state_network: invalid configuration');
    final nodes = config['nodes'] as List? ?? [];
    final inputs = config['inputs'] as List? ?? [];
    final ids = nodes.map((n) => n['id']).toList();
    final known = {...ids, ...inputs};
    if (known.length != ids.length + inputs.length) invalid();
    if (config['floor'] != null) {
      final routes = floorSources(config['floor']);
      if (routes.values.expand((v) => v).any((v) => !known.contains(v)))
        invalid();
      known.addAll(routes.keys);
    }
    const arities = {
      'copy': 1,
      'toggle': 1,
      'not': 1,
      'and': 2,
      'or': 2,
      'xor': 2,
      'counter2': 1,
      'counter3': 1,
      'latch': 2,
    };
    for (final n in nodes) {
      if (!arities.containsKey(n['op']) ||
          (n['inputs'] as List).length != arities[n['op']] ||
          (n['inputs'] as List).any((s) => !known.contains(s)) ||
          ![0, 1].contains(n['initial'] ?? 0)) invalid();
    }
    if (config['energy'] is! int || config['energy'] < 1) invalid();
    final probes = config['probes'] as Map? ?? {};
    if (probes.values.any((v) => !ids.contains(v))) invalid();
    if (config['initialProbe'] != null &&
        config['initialProbe'] != '' &&
        !probes.containsKey(config['initialProbe'])) invalid();
    bool validConditions(Map m) =>
        m.entries.every((e) => ids.contains(e.key) && [0, 1].contains(e.value));
    if (!validConditions(config['safe'] as Map? ?? {})) invalid();
    final tasks = config['tasks'] as Map? ?? {};
    for (final t in tasks.values) {
      if ((t['after'] as List? ?? []).any((task) => !tasks.containsKey(task)))
        invalid();
      if (!validConditions(t['requires'] as Map? ?? {}) ||
          (t['closes'] as List? ?? []).any((p) => !probes.containsKey(p)))
        invalid();
    }
    for (final a in (config['controls'] as Map? ?? {}).values) {
      final kind = a['type'];
      if (!['pulse', 'probe', 'clamp', 'commit'].contains(kind)) invalid();
      if (kind == 'pulse') {
        final values = a['inputs'] as Map? ?? {};
        if (values.length != inputs.length ||
            inputs.any((s) => !values.containsKey(s)) ||
            values.values.any((v) => ![0, 1].contains(v))) invalid();
      }
      if (kind == 'probe' && !probes.containsKey(a['target'])) invalid();
      if (kind == 'clamp' && !['', ...ids].contains(a['target'] ?? ''))
        invalid();
      if (kind == 'commit' && !tasks.containsKey(a['target'])) invalid();
    }
  }

  String get key => '__network_$id';
  Map runtime(LevelState state) {
    state.variables.putIfAbsent(
      key,
      () => <String, dynamic>{
        'values': {
          for (final n in config['nodes']) n['id'] as String: n['initial'] ?? 0,
        },
        'inputs': {
          for (final s in config['inputs'] as List? ?? []) s as String: 0,
        },
        if ((config['nodes'] as List)
            .any((n) => (n['op'] as String).startsWith('counter')))
          'counters': {
            for (final n in config['nodes'])
              if ((n['op'] as String).startsWith('counter'))
                n['id'] as String: 0
          },
        'energy': config['energy'],
        'probe': config['initialProbe'] ?? '',
        'clamp': '',
        'reading': -1,
        'sample': 'none',
        'done': <String>[],
        'closed': <String>[],
        'journal': <String>[],
        'complete': 0,
        'failed': 0,
      },
    );
    return state.variables[key] as Map;
  }

  Map<String, int> outputs(Map r) => {
        for (final e in (r['values'] as Map).entries)
          e.key as String: e.key == r['clamp'] ? 0 : e.value as int,
      };

  void project(LevelState state) {
    final r = runtime(state);
    final public = <String, dynamic>{
      for (final k in [
        'energy',
        'probe',
        'clamp',
        'reading',
        'sample',
        'complete',
        'failed',
      ])
        k: r[k],
      'journal': (r['journal'] as List).isEmpty
          ? 'No powered readings yet'
          : (r['journal'] as List).join(' | '),
      for (final inp in config['inputs'] as List? ?? [])
        'input_$inp': (r['inputs'] as Map?)?[inp] ?? 0,
      for (final task in (config['tasks'] as Map? ?? {}).keys)
        'done_$task': (r['done'] as List).contains(task) ? 1 : 0,
      for (final probe in (config['probes'] as Map? ?? {}).keys)
        'open_$probe': (r['closed'] as List).contains(probe) ? 0 : 1,
    };
    for (final e in (config['readouts'] as Map? ?? {}).entries) {
      if (!public.containsKey(e.key) ||
          (e.value as String).startsWith('__network_')) {
        throw ArgumentError('state_network: invalid public readout');
      }
      state.variables[e.value as String] = public[e.key];
    }
    for (final item in config['indicators'] as List? ?? []) {
      final kind = item['kinds'][public[item['field']].toString()];
      if (kind != null) {
        state.board.layers[item['layer']]!.setAt(
          Position.fromJson(item['position']),
          EntityInstance(kind),
        );
      }
    }
  }

  @override
  List<GameEvent> executeLoadSettle(LevelState state, GameDefinition game) {
    project(state);
    return const [];
  }

  @override
  List<GameEvent> executeActionResolution(
    GameAction action,
    LevelState state,
    GameDefinition game,
  ) {
    final r = runtime(state);
    final control = (config['controls'] as Map? ?? {})[action.actionId];
    if (control == null) return const [];
    final kind = control['type'], target = control['target'] ?? '';
    // Vetoes depend only on public state: action enumeration can probe them.
    if ((kind == 'probe' && (r['closed'] as List).contains(target)) ||
        (kind == 'commit' &&
            ((r['done'] as List).contains(target) ||
                (config['tasks'][target]['after'] as List? ?? [])
                    .any((t) => !(r['done'] as List).contains(t))))) {
      return const [
        GameEvent('action_vetoed', {'reason': 'unavailable'}),
      ];
    }
    if (kind == 'probe') {
      r['probe'] = target;
    } else if (kind == 'clamp') {
      r['clamp'] = target;
    } else {
      if (r['energy'] <= 0)
        return const [
          GameEvent('action_vetoed', {'reason': 'unavailable'}),
        ];
      r['energy'] = (r['energy'] as int) - 1;
      if (kind == 'pulse') {
        r['inputs'] = {
          for (final s in config['inputs'] as List? ?? [])
            s as String: control['inputs'][s] as int,
        };
        final signals = <String, dynamic>{
          ...outputs(r),
          ...Map<String, dynamic>.from(control['inputs']),
        };
        if (config['floor'] != null) {
          final routed = {
            for (final e in floorSources(config['floor']).entries)
              e.key: e.value.any((s) => signals[s] == 1) ? 1 : 0
          };
          signals.addAll(routed);
        }
        final next = <String, int>{};
        for (final n in config['nodes']) {
          final args =
              (n['inputs'] as List).map((s) => signals[s] as int).toList();
          next[n['id']] = nodeStep(n['op'], args, r['values'][n['id']],
              r['counters'] as Map? ?? {}, n['id']);
        }
        r['values'] = next;
        final probe = r['probe'] as String;
        r['sample'] = probe.isEmpty ? 'none' : probe;
        r['reading'] =
            probe.isNotEmpty && !(r['closed'] as List).contains(probe)
                ? outputs(r)[config['probes'][probe]]
                : -1;
        final bits =
            (config['inputs'] as List).map((s) => control['inputs'][s]).join();
        final clamp = r['clamp'] == '' ? '-' : r['clamp'];
        (r['journal'] as List).add(
          '$bits [$clamp] ${r['sample']}=${r['reading']}',
        );
      } else {
        final t = config['tasks'][target];
        final out = outputs(r);
        if ((t['requires'] as Map? ?? {}).entries.every(
              (e) => out[e.key] == e.value,
            )) {
          (r['done'] as List).add(target);
          r['closed'] = {
            ...r['closed'] as List,
            ...t['closes'] as List? ?? [],
          }.toList()
            ..sort();
          (r['journal'] as List).add('$target accepted');
        } else {
          r['failed'] = 1;
          (r['journal'] as List).add('$target failed');
        }
      }
    }
    r['complete'] = r['failed'] == 0 &&
            (r['done'] as List).length ==
                (config['tasks'] as Map? ?? {}).length &&
            (config['safe'] as Map? ?? {}).entries.every(
                  (e) => r['values'][e.key] == e.value,
                ) &&
            (config['parkCounters'] != true ||
                !(r['counters'] as Map? ?? {}).values.any((v) => v != 0))
        ? 1
        : 0;
    if (r['energy'] == 0 && r['complete'] == 0) r['failed'] = 1;
    project(state);
    return const [GameEvent('network_updated', {})];
  }
}
