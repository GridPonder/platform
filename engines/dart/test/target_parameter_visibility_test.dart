import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

String targetText(Object? rank,
    {bool symbolParam = false,
    bool anon = false,
    bool override = false,
    Map<String, dynamic> extra = const {},
    Map<String, dynamic>? lower,
    bool match = true}) {
  final game = GameDefinition.fromJson({
    'layers': [
      {'id': 'objects', 'occupancy': 'zero_or_one'},
      {'id': 'actors', 'occupancy': 'zero_or_one'},
    ],
    'entityKinds': {
      'cell': {
        'layer': 'objects',
        'symbol': 'C',
        if (symbolParam) 'symbolParam': 'rank',
      },
      'marker': {'layer': 'actors', 'symbol': 'M'},
    },
  });
  final values = {'rank': rank, ...extra};
  final level = LevelDefinition.fromJson({
    'id': 'target',
    'board': {
      'size': [1, 1],
      'layers': <String, dynamic>{}
    },
    'goals': [
      {
        'id': 'target',
        'type': 'board_match',
        'config': {
          if (match) 'matchParams': values.keys.toList(),
          'targetLayers': {
            'objects': [
              [
                {'kind': 'cell', ...values}
              ]
            ],
            if (lower != null)
              'actors': [
                [
                  {'kind': 'marker', ...lower}
                ]
              ],
          },
        },
      },
    ],
  }, game.layers);
  if (override) {
    game.goalDescriptions['target'] = 'Match the required values.';
  }
  return LlmAgent.describeGoals(level, level.initialState(), game,
      anonymize: anon,
      kindToLabel: anon ? {'cell': 'A', 'marker': 'B'} : const {});
}

void main() {
  test('non-symbol parameters distinguish targets', () {
    for (final anon in [false, true]) {
      final a = targetText(2, anon: anon), b = targetText(9, anon: anon);
      expect(a, isNot(b));
      expect(a, contains('"rank": 2'));
      expect(b, contains('"rank": 9'));
    }
  });

  test('multi-character values do not collapse to N', () {
    for (final anon in [false, true]) {
      final a = targetText(12, symbolParam: true, anon: anon);
      final b = targetText(19, symbolParam: true, anon: anon);
      expect(a, isNot(b));
      expect(a, contains('"rank": 12'));
      expect(b, contains('"rank": 19'));
    }
  });

  test('all required parameters preserve full JSON values', () {
    final text = targetText(2, extra: {
      'mode': 'two words',
      'active': false,
      'optional': null,
      'path': [1, 12],
    });
    expect(
        text,
        contains('{"active": false, "mode": "two words", '
            '"optional": null, "path": [1, 12], "rank": 2}'));
    expect(targetText(2), isNot(targetText('2')));
  });

  test('overrides keep required values', () {
    final text = targetText(12, override: true);
    expect(text, startsWith('Match the required values.\n'));
    expect(text, contains('"rank": 12'));
  });

  test('every layer at a coordinate has its own values', () {
    for (final anon in [false, true]) {
      final text = targetText(2, lower: {'rank': 9}, anon: anon);
      expect(text, contains('"rank": 2'));
      expect(text, contains('"rank": 9'));
      if (anon) {
        expect(text, isNot(contains('objects')));
        expect(text, isNot(contains('actors')));
        expect(text, contains('layer 1'));
        expect(text, contains('layer 2'));
        expect(
            text,
            contains('Target parameters: (0,0) layer 1 B {"rank": 9}; '
                '(0,0) layer 2 A {"rank": 2}'));
      } else {
        expect(text, contains('objects'));
        expect(text, contains('actors'));
        expect(
            text,
            contains('Target parameters: (0,0) actors M {"rank": 9}; '
                '(0,0) objects C {"rank": 2}'));
      }
    }
  });

  test('missing required values are distinct from explicit null', () {
    final text = targetText(null, lower: {});
    expect(text, contains('(0,0) actors M {} (missing required: ["rank"])'));
    expect(text, contains('(0,0) objects C {"rank": null}'));
  });

  test('unmatched parameters are not reported as requirements', () {
    expect(targetText(2, match: false), targetText(9, match: false));
    expect(targetText(2, match: false), isNot(contains('Target parameters:')));
  });
}
