import 'package:gridponder_engine/engine.dart';
import 'package:test/test.dart';

void main() {
  test('capacity follows live state independently of the starting value', () {
    final readout = GameReadout.fromJson({
      'variable': 'amount',
      'label': 'Amount',
      'maxVariable': 'capacity',
    });
    final variables = <String, dynamic>{'amount': 2, 'capacity': 3};
    expect(readout.formatValue(variables), '2/3');
    variables['capacity'] = 2;
    expect(readout.formatValue(variables), '2/2');
    variables['amount'] = 1;
    expect(readout.formatValue(variables), '1/2');
  });

  test('readouts without a known capacity retain their existing display', () {
    const readout = GameReadout(variable: 'amount', label: 'Amount');
    expect(readout.formatValue({'amount': 4}), '4');
    final missingCapacity = GameReadout.fromJson({
      'variable': 'amount',
      'maxVariable': 'capacity',
    });
    expect(missingCapacity.formatValue({'amount': 4}), '4');
  });

  test('blank readings retain their sentinel behavior with a capacity', () {
    const readout = GameReadout(
      variable: 'amount', label: 'Amount', blankWhen: -1,
      maxVariable: 'capacity',
    );
    expect(readout.formatValue({'amount': -1, 'capacity': 3}), '—');
    expect(readout.formatValue({'capacity': 3}), '—');
  });
}
