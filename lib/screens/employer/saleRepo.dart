import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/quantityUnit.dart';

// ============================================================================
// SALE — REPOSITORY
//   Search (sellable stock only), customers, create_sale / get_receipt RPCs,
//   today's sales list. Prices shown are selling prices; costs never leave
//   the server (create_sale records them from the batches it draws).
//
//   Fractional quantities: each item has a base unit (items.unit), a smallest
//   sale step (items.quantity_step) and optional bigger units (item_units,
//   e.g. 1 bottle = 100 ml). The cashier picks a unit and types a quantity in
//   it; the app converts to base units before calling create_sale.
// ============================================================================

class SaleException implements Exception {
  final String message;
  const SaleException(this.message);
  @override
  String toString() => message;
}

class SaleItem {
  final String itemId;
  final String name;
  final String category;
  final String unit; // base unit, e.g. "ml", "tablet", "g"
  final double retail; // price per base unit
  final double wholesale; // price per base unit
  final double available; // sellable base units: on hand + unexpired
  final double quantityStep; // smallest sale increment in base units (default 1)
  final List<QtyUnit> units; // bigger units (factor > 1), sorted by factor
  const SaleItem({
    required this.itemId,
    required this.name,
    required this.category,
    required this.unit,
    required this.retail,
    required this.wholesale,
    required this.available,
    this.quantityStep = 1,
    this.units = const [],
  });

  bool get inStock => available > 0;

  /// All units the cashier can sell in: the base unit first, then the bigger
  /// ones from item_units. Used by the cart line's unit picker.
  List<String> get sellableUnits => [unit, ...units.map((u) => u.name)];

  /// Price per [unitName] (base unit itself = 1). Falls back to the base
  /// price when the unit is unknown.
  double priceFor(String unitName) => retail * factorFor(unitName, unit, units);

  double wholesalePriceFor(String unitName) =>
      wholesale * factorFor(unitName, unit, units);
}

class SaleCustomer {
  final String id;
  final String name;
  final String phone;
  final double balance;
  const SaleCustomer({required this.id, required this.name, required this.phone, required this.balance});
}

class TodaySale {
  final String id;
  final String time;
  final String receipt;
  final double total;
  final String method;
  const TodaySale({
    required this.id,
    required this.time,
    required this.receipt,
    required this.total,
    required this.method,
  });
}

class SaleRepository {
  SaleRepository({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<String>> fetchCategories() async {
    final cats = <String>{};
    String? lastId;
    while (true) {
      dynamic q = _client.from('items').select('id, category').eq('is_active', true);
      if (lastId != null) q = q.gt('id', lastId);
      final rows = await q.order('id').limit(100) as List;
      if (rows.isEmpty) break;
      for (final r in rows) {
        final c = (r['category'] as String?)?.trim();
        if (c != null && c.isNotEmpty) cats.add(c);
      }
      lastId = rows.last['id'] as String;
    }
    return cats.toList()..sort();
  }

  Future<List<ReportBranchLite>> fetchBranches() async {
    final rows = await _client.from('branches').select('id, name').eq('is_active', true).order('name') as List;
    return rows.map((r) => ReportBranchLite(id: r['id'] as String, name: r['name'] as String)).toList();
  }

  /// Items with their sellable quantity at [branchId]. Expired batches and
  /// empty stock count as zero (greyed out, cannot be added).
  Future<List<SaleItem>> searchItems({required String branchId, String query = '', String? category}) async {
    dynamic q = _client.from('items').select('id, name, category, unit, quantity_step, item_units(unit_name, factor)').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    if (category != null) q = q.eq('category', category);
    final items = await q.order('name').limit(60) as List;
    if (items.isEmpty) return [];

    final ids = items.map((r) => r['id'] as String).toList();
    final stock = await _client
        .from('v_sellable_stock')
        .select('item_id, sellable_quantity, retail_price, wholesale_price')
        .eq('branch_id', branchId)
        .inFilter('item_id', ids)
        .limit(2000) as List;
    final byItem = <String, Map>{};
    for (final r in stock) {
      byItem[r['item_id'] as String] = r as Map;
    }

    final out = <SaleItem>[];
    for (final it in items) {
      final id = it['id'] as String;
      final batch = byItem[id];
      final avail = ((batch?['sellable_quantity'] as num?) ?? 0).toDouble();
      final retail = ((batch?['retail_price'] as num?) ?? 0).toDouble();
      final wholesale = ((batch?['wholesale_price'] as num?) ?? retail).toDouble();
      out.add(SaleItem(
        itemId: id,
        name: (it['name'] as String?) ?? '—',
        category: (it['category'] as String?) ?? 'Uncategorised',
        unit: (it['unit'] as String?) ?? 'unit',
        retail: retail,
        wholesale: wholesale,
        available: avail,
        quantityStep: ((it['quantity_step'] as num?) ?? 1).toDouble(),
        units: parseQtyUnits(it['item_units']),
      ));
    }
    // In-stock first, then alphabetical.
    out.sort((a, b) {
      if (a.inStock != b.inStock) return a.inStock ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Future<List<SaleCustomer>> searchCustomers({required String branchId, String query = ''}) async {
    dynamic q = _client.from('customers').select('id, name, phone, current_balance').eq('branch_id', branchId);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final rows = await q.order('name').limit(20) as List;
    return rows
        .map((r) => SaleCustomer(
              id: r['id'] as String,
              name: (r['name'] as String?) ?? '—',
              phone: (r['phone'] as String?) ?? '',
              balance: ((r['current_balance'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<SaleCustomer> createCustomer({required String branchId, required String name, String phone = ''}) async {
    if (name.trim().isEmpty) throw const SaleException('Customer name is required.');
    final row = await _client.from('customers').insert({
      'branch_id': branchId,
      'name': name.trim(),
      'phone': phone.trim().isEmpty ? null : phone.trim(),
    }).select('id, name, phone, current_balance').single();
    return SaleCustomer(
      id: row['id'] as String,
      name: (row['name'] as String?) ?? '—',
      phone: (row['phone'] as String?) ?? '',
      balance: ((row['current_balance'] as num?) ?? 0).toDouble(),
    );
  }

  Future<List<TodaySale>> todaySales({required String branchId}) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final rows = await _client
        .from('sales')
        .select('id, sale_date, receipt_number, total_amount, payment_method')
        .eq('branch_id', branchId)
        .gte('sale_date', start.toIso8601String())
        .lt('sale_date', start.add(const Duration(days: 1)).toIso8601String())
        .order('sale_date', ascending: false)
        .limit(100) as List;
    return rows
        .map((r) => TodaySale(
              id: r['id'] as String,
              time: (r['sale_date'] as String?) ?? '',
              receipt: (r['receipt_number'] as String?) ?? '—',
              total: ((r['total_amount'] as num?) ?? 0).toDouble(),
              method: (r['payment_method'] as String?) ?? '',
            ))
        .toList();
  }

  /// Calls create_sale (schema.sql). The server resolves the branch from the
  /// signed-in user; p_branch_id is only used for admins. Server messages
  /// are already plain language, so they are shown as-is.
  ///
  /// Each line may carry a `unit` (e.g. "bottle"); the server converts the
  /// quantity to the item's base unit via to_base_qty(). Omit it (or leave it
  /// null) when the quantity is already in base units.
  Future<Map<String, dynamic>> createSale({
    required String branchId,
    required List<Map<String, dynamic>> lines, // [{item_id, quantity, unit?}]
    required String saleType, // retail | wholesale
    required String method, // cash | airtel_money | tnm_mpamba | card | credit
    String? customerId,
    double? partPayment,
    String? partMethod,
  }) async {
    try {
      final res = await _client.rpc('create_sale', params: {
        'p_branch_id': branchId,
        'p_lines': lines,
        'p_sale_type': saleType,
        'p_payment_method': method,
        'p_customer_id': ?customerId,
        if (partPayment != null && partPayment > 0) 'p_amount_paid': partPayment,
        'p_paid_method': ?partMethod,
      });
      return Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      throw SaleException(_friendly(e.message));
    }
  }

  Future<Map<String, dynamic>> getReceipt(String saleId) async {
    try {
      final res = await _client.rpc('get_receipt', params: {'p_sale_id': saleId});
      return Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      throw SaleException(_friendly(e.message));
    }
  }

  String _friendly(String server) {
    // schema.sql raises plain-language messages already
    // ('Not enough stock for AMLODIPINE: only 3 available.') — show as-is.
    final msg = server.trim();
    return msg.isEmpty ? 'Something went wrong. Please try again.' : msg;
  }

}

class ReportBranchLite {
  final String id;
  final String name;
  const ReportBranchLite({required this.id, required this.name});
}
