// lib/core/quantityUnits.dart
// Shared helpers for fractional / multi-unit quantities.
// All quantities in the database are in the item's BASE unit (items.unit).

/// A bigger (or alternative) unit for an item: 1 [name] = [factor] base units.
class QtyUnit {
  final String name;
  final double factor;
  const QtyUnit(this.name, this.factor);
}

/// Parses the `item_units(unit_name, factor)` embed from PostgREST.
List<QtyUnit> parseQtyUnits(dynamic raw) {
  if (raw is! List) return const [];
  final out = <QtyUnit>[
    for (final u in raw)
      if (u is Map && u['unit_name'] != null && u['factor'] != null)
        QtyUnit(u['unit_name'] as String, (u['factor'] as num).toDouble()),
  ]..sort((a, b) => a.factor.compareTo(b.factor));
  return out;
}

/// The database stores 2 decimals; keep Dart doubles in line with that.
double roundQty(double v) => (v * 100).roundToDouble() / 100;

/// True when [qty] is a whole multiple of [step] (float-safe).
bool onStep(double qty, double step) {
  if (step <= 0) return true;
  final s = qty / step;
  return (s - s.roundToDouble()).abs() < 1e-6;
}

/// "5", "0.5", "12.25" (no trailing zeros).
String fmtQty(num q) {
  final v = q.toDouble();
  if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(2);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return s;
}

/// Base units contained in one [unitName]. Base unit itself = 1.
double factorFor(String unitName, String baseUnit, List<QtyUnit> units) {
  final target = unitName.trim().toLowerCase();
  if (target == baseUnit.trim().toLowerCase()) return 1;
  for (final u in units) {
    if (u.name.trim().toLowerCase() == target) return u.factor;
  }
  return 1;
}

/// Price per base unit from a price typed per [factor] base units
/// (e.g. MK 1500 per bottle of 100 ml -> 15.00 per ml).
/// Returns null when rounding to 2 decimals would distort the price by
/// more than 1% (the database keeps prices to 2 decimals).
double? pricePerBase(double pricePerUnit, double factor) {
  if (factor <= 0) return null;
  final per = roundQty(pricePerUnit / factor);
  if (pricePerUnit == 0) return 0;
  final back = per * factor;
  if ((back - pricePerUnit).abs() / pricePerUnit > 0.01) return null;
  return per;
}