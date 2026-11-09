import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/quantityUnit.dart';

// ============================================================================
// CASHIER STOCK — branch stock list + receive flow for staff with access.
//   Receiving goes through receive_stock_delivery() (one atomic call).
//   Access state comes from has_stock_access() + the cashier's own rows in
//   v_stock_access_requests. Buying prices are only ever typed into the
//   receive form — never shown on list rows.
// ============================================================================

// Bumped whenever branch stock changes elsewhere (receiving, adjustments)
// so the sale list refreshes its quantities.
final stockChanged = ValueNotifier<int>(0);

class StockException implements Exception {
  final String message;
  const StockException(this.message);
  @override
  String toString() => message;
}

class BranchStockRow {
  final String itemId;
  final String name;
  final String category;
  final String unit;
  final double qty;
  final double retail;
  final bool low;
  final bool expiring;
  const BranchStockRow({
    required this.itemId,
    required this.name,
    required this.category,
    required this.unit,
    required this.qty,
    required this.retail,
    required this.low,
    required this.expiring,
  });
}

class CatalogOption {
  final String id;
  final String name;
  const CatalogOption({required this.id, required this.name});
}

class EmployeeCatalogItem {
  final String id;
  final String name;
  final String category;
  final String unit;
  final double reorderLevel;
  final double quantityStep;
  final bool requiresPrescription;
  final String businessTypeId;
  final String businessTypeName;
  final bool isActive;
  final List<QtyUnit> units;

  const EmployeeCatalogItem({
    required this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.reorderLevel,
    this.quantityStep = 1,
    this.requiresPrescription = false,
    required this.businessTypeId,
    required this.businessTypeName,
    this.isActive = true,
    this.units = const [],
  });
}

class ExistingCatalogMatch {
  final String name;
  final String unit;
  final String businessType;
  const ExistingCatalogMatch({
    required this.name,
    required this.unit,
    required this.businessType,
  });
}

class BusinessTypeOption {
  final String id;
  final String name;
  const BusinessTypeOption({required this.id, required this.name});
}

class SupplierOption {
  final String id;
  final String name;
  const SupplierOption({required this.id, required this.name});
}

enum OwnAccessState { none, pending, active }

class OwnAccess {
  final OwnAccessState state;
  final String? requestId;
  final DateTime? expiresAt;
  final DateTime? decidedAt;
  const OwnAccess({required this.state, this.requestId, this.expiresAt, this.decidedAt});
}

class ReceiveLine {
  final String itemId;
  final double quantity;
  final double buyingPrice;
  final double retailPrice;
  final double? wholesalePrice;
  final String? expiryDate; // YYYY-MM-DD
  final String? batchNumber;
  const ReceiveLine({
    required this.itemId,
    required this.quantity,
    required this.buyingPrice,
    required this.retailPrice,
    this.wholesalePrice,
    this.expiryDate,
    this.batchNumber,
  });

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'quantity': quantity,
        'buying_price': buyingPrice,
        'retail_price': retailPrice,
        if (wholesalePrice != null) 'wholesale_price': wholesalePrice,
        if (expiryDate != null && expiryDate!.isNotEmpty) 'expiry_date': expiryDate,
        if (batchNumber != null && batchNumber!.trim().isNotEmpty) 'batch_number': batchNumber!.trim(),
      };
}

class CashierStockRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<List<BranchStockRow>> fetchStock({required String branchId, String query = ''}) async {
    dynamic q = _client.from('items').select('id, name, category, unit, reorder_level').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final items = await q.order('name').limit(200) as List;
    if (items.isEmpty) return [];
    final ids = items.map((r) => r['id'] as String).toList();
    final today = _todayStr();
    final stock = await _client
        .from('inventory')
        .select('item_id, quantity_available, retail_price, expiry_date')
        .eq('branch_id', branchId)
        .inFilter('item_id', ids)
        .gt('quantity_available', 0)
        .limit(2000) as List;

    final qtyBy = <String, double>{};
    final priceBy = <String, double>{};
    final expiring = <String>{};
    for (final r in stock) {
      final id = r['item_id'] as String;
      final qty = ((r['quantity_available'] as num?) ?? 0).toDouble();
      qtyBy[id] = (qtyBy[id] ?? 0) + qty;
      final retail = ((r['retail_price'] as num?) ?? 0).toDouble();
      if (!priceBy.containsKey(id) || retail < priceBy[id]!) priceBy[id] = retail;
      final exp = r['expiry_date'] as String?;
      if (exp != null && exp.compareTo(today) >= 0) {
        try {
          final d = DateTime.parse(exp);
          final now = DateTime.now();
          if (d.difference(DateTime(now.year, now.month, now.day)).inDays <= 90) {
            expiring.add(id);
          }
        } catch (_) {}
      }
    }
    final out = <BranchStockRow>[];
    for (final it in items) {
      final id = it['id'] as String;
      final qty = qtyBy[id] ?? 0;
      final reorder = ((it['reorder_level'] as num?) ?? 10).toDouble();
      out.add(BranchStockRow(
        itemId: id,
        name: (it['name'] as String?) ?? '—',
        category: (it['category'] as String?) ?? 'Uncategorised',
        unit: (it['unit'] as String?) ?? 'unit',
        qty: qty,
        retail: priceBy[id] ?? 0,
        low: qty <= reorder,
        expiring: expiring.contains(id),
      ));
    }
    return out;
  }

  Future<List<CatalogOption>> searchCatalog(String query) async {
    dynamic q = _client.from('items').select('id, name').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final rows = await q.order('name').limit(30) as List;
    return rows.map((r) => CatalogOption(id: r['id'] as String, name: (r['name'] as String?) ?? '—')).toList();
  }

  Future<List<EmployeeCatalogItem>> fetchCatalog({String query = '', bool includeInactive = false}) async {
    dynamic q = _client.from('items').select(
      'id, name, category, unit, reorder_level, requires_prescription, is_active, business_type_id, business_types(name), quantity_step, item_units(unit_name, factor)',
    );
    if (!includeInactive) q = q.eq('is_active', true);
    if (query.trim().isNotEmpty) {
      q = q.ilike('name', '%${query.trim()}%');
    }
    final rows = await q.order('name').limit(2000) as List;
    return rows.map((r) {
      final bt = r['business_types'];
      final btName = bt is Map ? (bt['name'] as String? ?? 'Pharmacy') : 'Pharmacy';
      return EmployeeCatalogItem(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '—',
        category: (r['category'] as String?)?.trim().isNotEmpty == true
            ? (r['category'] as String).trim()
            : 'Uncategorised',
        unit: (r['unit'] as String?) ?? 'unit',
        reorderLevel: ((r['reorder_level'] as num?) ?? 10).toDouble(),
        requiresPrescription: (r['requires_prescription'] as bool?) ?? false,
        isActive: (r['is_active'] as bool?) ?? true,
        businessTypeId: (r['business_type_id'] as String?) ?? '',
        businessTypeName: btName,
        quantityStep: ((r['quantity_step'] as num?) ?? 1).toDouble(),
        units: parseQtyUnits(r['item_units']),
      );
    }).toList();
  }

  /// Exact (case-insensitive) name match already in the catalog, for the
  /// duplicate warning on the add-product form. Note: staff RLS only shows
  /// items of their own branch's business types, so a same-named item under
  /// a type this branch doesn't run is invisible here — the admin-side
  /// check (which sees everything) remains the backstop.
  Future<List<ExistingCatalogMatch>> findItemsByName(String name) async {
    try {
      final clean = name.trim();
      if (clean.isEmpty) return [];
      // Escape LIKE wildcards so a name like "100%" can't match "1000".
      final pattern = clean
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      final rows = await _client
          .from('items')
          .select('name, unit, business_types(name)')
          .ilike('name', pattern)
          .limit(10) as List;
      final lower = clean.toLowerCase();
      final out = <ExistingCatalogMatch>[];
      for (final r in rows) {
        final n = (r['name'] as String?) ?? '';
        if (n.trim().toLowerCase() != lower) continue;
        final bt = r['business_types'];
        out.add(ExistingCatalogMatch(
          name: n,
          unit: (r['unit'] as String?) ?? 'unit',
          businessType: bt is Map ? (bt['name'] as String? ?? '') : '',
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<SupplierOption>> fetchSuppliers() async {
    final rows = await _client.from('suppliers').select('id, name').eq('is_active', true).order('name').limit(200) as List;
    return rows.map((r) => SupplierOption(id: r['id'] as String, name: (r['name'] as String?) ?? '—')).toList();
  }

  Future<bool> hasAccess() async {
    try {
      final res = await _client.rpc('has_stock_access');
      return res as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<OwnAccess> myStatus() async {
    try {
      final rows = await _client.from('v_stock_access_requests').select('id, effective_status, expires_at, decided_at').limit(50) as List;
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'pending') {
          return const OwnAccess(state: OwnAccessState.pending);
        }
      }
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'approved') {
          DateTime? dt(Object? v) {
            if (v == null) return null;
            try {
              return DateTime.parse(v as String);
            } catch (_) {
              return null;
            }
          }

          return OwnAccess(
            state: OwnAccessState.active,
            requestId: r['id'] as String,
            expiresAt: dt(r['expires_at']),
            decidedAt: dt(r['decided_at']),
          );
        }
      }
      return const OwnAccess(state: OwnAccessState.none);
    } catch (_) {
      return const OwnAccess(state: OwnAccessState.none);
    }
  }

  Future<void> requestAccess(String reason) async {
    try {
      await _client.rpc('request_stock_access', params: {'p_reason': reason.trim().isEmpty ? null : reason.trim()});
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> endOwnAccess(String requestId) async {
    try {
      await _client.rpc('revoke_stock_access', params: {'p_request_id': requestId});
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  // ---- Catalog access & additions --------------------------------------------

  Future<bool> hasCatalogAccess() async {
    try {
      final res = await _client.rpc('has_catalog_access');
      return res as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<OwnAccess> myCatalogStatus() async {
    try {
      final rows = await _client
          .from('v_catalog_access_requests')
          .select('id, effective_status, expires_at, decided_at')
          .limit(50) as List;
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'pending') {
          return const OwnAccess(state: OwnAccessState.pending);
        }
      }
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'approved') {
          DateTime? dt(Object? v) {
            if (v == null) return null;
            try {
              return DateTime.parse(v as String);
            } catch (_) {
              return null;
            }
          }

          return OwnAccess(
            state: OwnAccessState.active,
            requestId: r['id'] as String,
            expiresAt: dt(r['expires_at']),
            decidedAt: dt(r['decided_at']),
          );
        }
      }
      return const OwnAccess(state: OwnAccessState.none);
    } catch (_) {
      return const OwnAccess(state: OwnAccessState.none);
    }
  }

  Future<void> requestCatalogAccess(String reason) async {
    try {
      final clean = reason.trim();
      // Omit p_reason when empty (uses the DEFAULT NULL) instead of
      // sending an explicit null — same pattern as receive() below.
      if (clean.isEmpty) {
        await _client.rpc('request_catalog_access');
      } else {
        await _client.rpc('request_catalog_access', params: {'p_reason': clean});
      }
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> endOwnCatalogAccess(String requestId) async {
    try {
      await _client.rpc('revoke_catalog_access', params: {
        'p_request_id': requestId,
      });
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<List<BusinessTypeOption>> fetchBranchBusinessTypes(String branchId) async {
    try {
      final rows = await _client
          .from('branch_business_types')
          .select('business_type_id, business_types(id, name)')
          .eq('branch_id', branchId) as List;
      final out = <BusinessTypeOption>[];
      for (final r in rows) {
        final bt = r['business_types'];
        if (bt is Map) {
          out.add(BusinessTypeOption(
            id: bt['id'] as String,
            name: bt['name'] as String,
          ));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<CatalogOption> addCatalogItem({
    required String name,
    required String businessTypeId,
    String? category,
    String? unit,
    double? reorderLevel,
    bool requiresPrescription = false,
  }) async {
    if (name.trim().isEmpty) {
      throw const StockException('Item name is required.');
    }
    if (businessTypeId.trim().isEmpty) {
      throw const StockException('Please select a business type.');
    }
    try {
      final res = await _client.rpc('add_catalog_item', params: {
        'p_name': name.trim(),
        'p_business_type_id': businessTypeId,
        'p_category': category?.trim().isEmpty == true ? null : category?.trim(),
        'p_unit': unit?.trim().isEmpty == true ? 'unit' : unit?.trim(),
        'p_reorder_level': reorderLevel ?? 10,
        'p_requires_prescription': requiresPrescription,
      });
      return CatalogOption(id: res as String, name: name.trim());
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> receive({
    required String branchId,
    String? supplierId,
    String? invoice,
    required List<ReceiveLine> lines,
  }) async {
    if (lines.isEmpty) throw const StockException('Add at least one delivery line.');
    try {
      await _client.rpc('receive_stock_delivery', params: {
        'p_branch_id': branchId,
        'p_supplier_id': ?supplierId,
        if (invoice != null && invoice.trim().isNotEmpty) 'p_invoice_number': invoice.trim(),
        'p_lines': [for (final l in lines) l.toJson()],
      });
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }
}
