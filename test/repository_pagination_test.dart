import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:tumaini/screens/admin/inventoryRepo.dart';
import 'package:tumaini/screens/employer/saleRepo.dart';
import 'package:tumaini/screens/employer/stockRepo.dart';

String id(int n) => n.toString().padLeft(5, '0');

class FakePostgrest {
  FakePostgrest(this.tables, {this.cap = 37});

  final Map<String, List<Map<String, dynamic>>> tables;
  final int cap;
  final requests = <Uri>[];

  SupabaseClient client() => SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    httpClient: MockClient((request) async {
      final uri = request.url;
      requests.add(uri);
      final params = uri.queryParameters;
      var rows = List<Map<String, dynamic>>.of(
        tables[uri.pathSegments.last] ?? [],
      );
      for (final entry in params.entries) {
        final value = entry.value;
        if (value.startsWith('eq.')) {
          rows = rows
              .where((r) => '${r[entry.key]}' == value.substring(3))
              .toList();
        } else if (value.startsWith('gt.')) {
          final operand = value.substring(3);
          rows = rows.where((r) {
            final v = r[entry.key];
            return v is num
                ? v > num.parse(operand)
                : '$v'.compareTo(operand) > 0;
          }).toList();
        } else if (value.startsWith('ilike.')) {
          final term = value.substring(6).replaceAll('%', '').toLowerCase();
          rows = rows
              .where((r) => '${r[entry.key]}'.toLowerCase().contains(term))
              .toList();
        } else if (value.startsWith('in.(')) {
          final ids = value
              .substring(4, value.length - 1)
              .split(',')
              .map((s) => s.replaceAll('"', ''))
              .toSet();
          rows = rows.where((r) => ids.contains('${r[entry.key]}')).toList();
        }
      }
      final order = params['order'];
      if (order != null) {
        final key = order.split('.').first;
        rows.sort((a, b) => '${a[key]}'.compareTo('${b[key]}'));
      }
      final limit = int.tryParse(params['limit'] ?? '') ?? cap;
      return http.Response(
        jsonEncode(rows.take(limit < cap ? limit : cap).toList()),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
}

List<Map<String, dynamic>> items(int count) => List.generate(
  count,
  (i) => {
    'id': id(i),
    'name': 'Product ${id(count - i)}',
    'category': i == 2 ? 'Inactive' : (i == count - 1 ? ' Zebra ' : 'Alpha'),
    'is_active': i != 2,
    'unit': 'box',
    'reorder_level': 2,
  },
);

Map<String, dynamic> batch(
  int n,
  String itemId, {
  String branch = 'b',
  int qty = 1,
  int price = 5,
}) => {
  'id': id(n),
  'item_id': itemId,
  'branch_id': branch,
  'quantity_available': qty,
  'quantity_received': qty,
  'buying_price': 2,
  'retail_price': price,
  'items': {
    'id': itemId,
    'name': itemId == id(0) ? 'Zed' : 'Alpha',
    'is_active': true,
  },
  'branches': {'name': 'Main'},
};

void main() {
  test(
    'admin catalog and categories traverse capped pages beyond 1000 and sort',
    () async {
      final fake = FakePostgrest({'items': items(1105)});
      final repo = InventoryRepository(client: fake.client());
      final catalog = await repo.fetchCatalog();
      expect(catalog.length, 1105);
      expect(catalog.map((e) => e.id).toSet().length, 1105);
      expect(catalog.first.name, 'Product 00001');
      expect(catalog.last.name, 'Product 01105');
      final active = await repo.fetchCatalog(includeInactive: false);
      expect(active.length, 1104);
      expect(active.any((e) => e.id == id(2)), isFalse);
      expect(await repo.fetchCategories(), ['Alpha', 'Inactive', 'Zebra']);
      expect(
        fake.requests.where((r) => r.queryParameters.containsKey('id')),
        isNotEmpty,
      );
    },
  );

  test('admin overview paginates batches and retains branch and positive stock filters', () async {
    final stock = List.generate(1050, (i) => batch(i, id(i % 2)))
      ..add(batch(2000, id(0), branch: 'other'))
      ..add(batch(2001, id(0), qty: 0));
    final fake = FakePostgrest({'inventory': stock});
    final result = await InventoryRepository(client: fake.client())
        .fetchOverview(branchId: 'b');
    expect(result.map((e) => e.itemName), ['Alpha', 'Zed']);
    expect(result.fold<int>(0, (n, e) => n + e.batches.length), 1050);
    expect(result.every((e) => e.qtyOnHand == 525), isTrue);
    expect(
      fake.requests.every(
        (r) =>
            r.queryParameters['branch_id'] == 'eq.b' &&
            r.queryParameters['quantity_available'] == 'gt.0',
      ),
      isTrue,
    );
  });

  test(
    'cashier stock paginates items and batches across 300-ID chunks',
    () async {
      final stock =
          List.generate(120, (i) => batch(i, id(0), price: i == 119 ? 2 : 5))
            ..add(batch(200, id(300)))
            ..add(batch(201, id(0), branch: 'other', qty: 100))
            ..add(batch(202, id(0), qty: 0));
      final fake = FakePostgrest({
        'items': items(305),
        'inventory': stock,
      }, cap: 17);
      final rows = await CashierStockRepository(client: fake.client())
          .fetchStock(branchId: 'b', query: ' Product ');
      expect(rows.length, 304);
      expect(rows.first.name, 'Product 00001');
      final first = rows.singleWhere((r) => r.itemId == id(0));
      expect(first.qty, 120);
      expect(first.retail, 2);
      expect(rows.singleWhere((r) => r.itemId == id(300)).qty, 1);
      final itemRequests = fake.requests.where(
        (r) => r.pathSegments.last == 'items',
      );
      expect(
        itemRequests.every(
          (r) =>
              r.queryParameters['is_active'] == 'eq.true' &&
              r.queryParameters['name'] == 'ilike.%Product%',
        ),
        isTrue,
      );
      final stockRequests = fake.requests.where(
        (r) => r.pathSegments.last == 'inventory',
      );
      expect(
        stockRequests.every(
          (r) =>
              r.queryParameters['branch_id'] == 'eq.b' &&
              r.queryParameters['quantity_available'] == 'gt.0',
        ),
        isTrue,
      );
      expect(
        stockRequests.map((r) => r.queryParameters['item_id']).toSet().length,
        2,
      );
    },
  );

  test(
    'cashier catalog and sale categories keep active filters on capped pages',
    () async {
      final fake = FakePostgrest({'items': items(105)}, cap: 13);
      final catalog = await CashierStockRepository(client: fake.client())
          .fetchCatalogList(query: ' Product ');
      expect(catalog.length, 104);
      expect(catalog.first.name, 'Product 00001');
      expect(catalog.last.name, 'Product 00105');
      expect(await SaleRepository(client: fake.client()).fetchCategories(), [
        'Alpha',
        'Zebra',
      ]);
      expect(
        fake.requests.every((r) => r.queryParameters['is_active'] == 'eq.true'),
        isTrue,
      );
    },
  );

  test('empty item results do not request inventory', () async {
    final fake = FakePostgrest({'items': []});
    final rows = await CashierStockRepository(client: fake.client())
        .fetchStock(branchId: 'b');
    expect(rows, isEmpty);
    expect(fake.requests.map((r) => r.pathSegments.last), ['items']);
  });
}
