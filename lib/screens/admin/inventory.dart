import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../../core/downloads.dart';
import '../../core/quantityUnit.dart';
import '../../widgets/adminShell.dart';
import 'adminui.dart';
import 'inventoryRepo.dart';
import 'stockAccessRepo.dart';

final inventoryAttentionRequest = ValueNotifier<bool>(false);

// ============================================================================
// ADMIN INVENTORY — oversight and decisions, not data entry.
//   Embedded page inside AdminShell (nav bars stay visible — this screen only
//   ever opens sheets/dialogs, it never pushes a route).
//
//   Filter bar (branch, search, category) scopes everything: the summary
//   cards, all six tabs and every export. Tabs:
//     0 Stock overview · 1 Low stock · 2 Expiry · 3 Movements ·
//     4 Purchases · 5 Item catalog (the only place the admin edits data).
//
//   Desktop: sidebar stays, cards in one row, tabs as chips, full tables,
//   batches expand inline. Mobile: search + Filters button, swipeable cards,
//   chips row, stacked cards, actions in bottom sheets.
// ============================================================================

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

const _kTabs = [
  'Overview',
  'Low stock',
  'Expiry',
  'Movements',
  'Purchases',
  'Catalog',
];
const _kMovementTypes = [
  'purchase_in',
  'sale_out',
  'adjustment_in',
  'adjustment_out',
  'opening_stock',
];

String _fmtMk(double amount) {
  final neg = amount < 0;
  final s = amount.abs().round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${neg ? '-' : ''}$buf';
}

String _fmtQty(double q) =>
    q.toStringAsFixed(q.truncateToDouble() == q ? 0 : 2);

String _fmtDate(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  try {
    final d = DateTime.parse(raw);
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  } catch (_) {
    return raw;
  }
}

String _fmtDateTime(String raw) {
  if (raw.isEmpty) return '—';
  try {
    final d = DateTime.parse(raw).toLocal();
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${m[d.month - 1]}, $hh:$mm';
  } catch (_) {
    return raw;
  }
}

String _csvCell(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

class _MovementMeta {
  final String label;
  final IconData icon;
  final Color color;
  final bool isOut;
  const _MovementMeta(this.label, this.icon, this.color, this.isOut);
}

_MovementMeta _movementMeta(String type) {
  switch (type) {
    case 'purchase_in':
      return const _MovementMeta(
        'Purchase',
        Icons.shopping_cart_outlined,
        kSuccess,
        false,
      );
    case 'sale_out':
      return const _MovementMeta(
        'Sale',
        Icons.point_of_sale_outlined,
        kPrimary,
        true,
      );
    case 'adjustment_out':
      return const _MovementMeta(
        'Adjustment out',
        Icons.remove_circle_outline,
        kDanger,
        true,
      );
    case 'adjustment_in':
      return const _MovementMeta(
        'Adjustment in',
        Icons.add_circle_outline,
        kSuccess,
        false,
      );
    case 'opening_stock':
      return const _MovementMeta(
        'Opening',
        Icons.inventory_2_outlined,
        kInkMuted,
        false,
      );
    default:
      return _MovementMeta(type, Icons.swap_horiz_outlined, kInkMuted, false);
  }
}

class _InventoryScreenState extends State<InventoryScreen> {
  final _repo = InventoryRepository();
  final _searchCtrl = TextEditingController();

  List<InvBranch> _branches = [];
  List<String> _categories = [];
  String? _branchId; // null = all branches
  String _search = '';
  String? _category; // null = all categories
  bool _showInactive = false;
  String? _movementType; // null = all types
  int _tab = 0;

  // Stock-access "View activity" deep-link: movements filtered to one
  // cashier + the window their access was active. Removable via chip.
  String? _activityUserId;
  String? _activityUserName;
  DateTime? _activityFrom;
  DateTime? _activityTo;
  bool _wasInventorySelected = false;
  bool _showNeedsAttention = false;
  int _attentionFilter = 0; // 0 all, 1 low stock, 2 expiring

  bool _loading = true;
  String? _error;

  List<ItemStock> _items = [];
  List<LowStockRow> _low = [];
  List<StockMovement> _movements = [];
  List<PurchaseOrder> _purchases = [];
  List<SupplierBalance> _balances = [];
  List<CatalogItem> _catalog = [];
  List<BusinessTypeOption> _businessTypes = [];
  List<String> _branchBusinessTypeIds = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pick up a "View activity" jump from the Stock access section: show
    // Movements scoped to that cashier + window (branch filter cleared so
    // the link always lands on results).
    final selected = AdminShellScope.of(context)?.selectedIndex == 1;
    if (selected && !_wasInventorySelected) {
      if (inventoryAttentionRequest.value) {
        inventoryAttentionRequest.value = false;
        setState(() {
          _showNeedsAttention = true;
          _attentionFilter = 0;
        });
      }
      final f = stockActivityFilter.value;
      if (f != null) {
        stockActivityFilter.value = null;
        setState(() {
          _tab = 3;
          _movementType = null;
          _branchId = null;
          _activityUserId = f.userId;
          _activityUserName = f.userName;
          _activityFrom = f.from;
          _activityTo = f.to;
        });
        _load();
      }
    }
    _wasInventorySelected = selected;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final futures = <Future<dynamic>>[
        _repo.fetchBranches(),
        _repo.fetchCategories(),
        _repo.fetchOverview(branchId: _branchId),
        _repo.fetchLowStock(branchId: _branchId),
        _repo.fetchMovements(
          branchId: _branchId,
          limit: 150,
          performedBy: _activityUserId,
          from: _activityFrom,
          to: _activityTo,
        ),
        _repo.fetchPurchases(branchId: _branchId),
        _repo.fetchSupplierBalances(),
        _repo.fetchCatalog(includeInactive: true),
        _repo.fetchBusinessTypes(),
        if (_branchId != null)
          _repo.fetchBranchBusinessTypeIds(_branchId!)
        else
          Future.value(<String>[]),
      ];
      final results = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _branches = results[0] as List<InvBranch>;
        _categories = results[1] as List<String>;
        _items = results[2] as List<ItemStock>;
        _low = results[3] as List<LowStockRow>;
        _movements = results[4] as List<StockMovement>;
        _purchases = results[5] as List<PurchaseOrder>;
        _balances = results[6] as List<SupplierBalance>;
        _catalog = results[7] as List<CatalogItem>;
        _businessTypes = results[8] as List<BusinessTypeOption>;
        _branchBusinessTypeIds = results[9] as List<String>;
        _loading = false;
        _invalidateFilterCaches();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Branch зміни → server refetch; search/category/type stay client-side.
  Future<void> _onBranchChanged(String? id) async {
    if (id == _branchId) return;
    setState(() {
      _branchId = id;
      _invalidateFilterCaches();
    });
    await _load();
  }

  // ---- Client-side filtering (search + category with memoization) -----------

  List<ItemStock>? _cachedVisibleItems;
  List<CatalogItem>? _cachedVisibleCatalog;
  List<StockMovement>? _cachedVisibleMovements;
  List<PurchaseOrder>? _cachedVisiblePurchases;
  List<List<StockBatch>>? _cachedExpiryBuckets;
  InventorySummary? _cachedSummary;

  void _invalidateFilterCaches() {
    _cachedVisibleItems = null;
    _cachedVisibleCatalog = null;
    _cachedVisibleMovements = null;
    _cachedVisiblePurchases = null;
    _cachedExpiryBuckets = null;
    _cachedSummary = null;
  }

  List<ItemStock> get _visibleItems {
    return _cachedVisibleItems ??= () {
      final q = _search.trim().toLowerCase();
      return _items.where((it) {
        if (_category != null && it.category != _category) return false;
        if (q.isEmpty) return true;
        if (it.itemName.toLowerCase().contains(q)) return true;
        return it.batches.any(
          (b) =>
              b.batchNumber.toLowerCase().contains(q) ||
              b.branchName.toLowerCase().contains(q),
        );
      }).toList();
    }();
  }

  List<CatalogItem> get _visibleCatalog {
    return _cachedVisibleCatalog ??= () {
      final q = _search.trim().toLowerCase();
      return _catalog.where((c) {
        if (!_showInactive && !c.isActive) return false;
        if (_category != null && c.category != _category) return false;
        if (_branchId != null && _branchBusinessTypeIds.isNotEmpty) {
          if (!_branchBusinessTypeIds.contains(c.businessTypeId)) return false;
        }
        if (q.isEmpty) return true;
        return c.name.toLowerCase().contains(q);
      }).toList();
    }();
  }

  List<StockMovement> get _visibleMovements {
    return _cachedVisibleMovements ??= () {
      final q = _search.trim().toLowerCase();
      return _movements.where((m) {
        if (_movementType != null && m.type != _movementType) return false;
        if (q.isEmpty) return true;
        return m.itemName.toLowerCase().contains(q) ||
            m.branchName.toLowerCase().contains(q) ||
            (m.notes ?? '').toLowerCase().contains(q);
      }).toList();
    }();
  }

  List<PurchaseOrder> get _visiblePurchases {
    return _cachedVisiblePurchases ??= () {
      final q = _search.trim().toLowerCase();
      if (q.isEmpty) return _purchases;
      return _purchases.where((p) {
        return p.supplierName.toLowerCase().contains(q) ||
            p.branchName.toLowerCase().contains(q) ||
            p.invoiceNumber.toLowerCase().contains(q);
      }).toList();
    }();
  }

  /// Expiry buckets derived from the visible items: expired / <30 / 30-60 / 60-90.
  List<List<StockBatch>> _expiryBuckets() {
    return _cachedExpiryBuckets ??= () {
      final expired = <StockBatch>[];
      final u30 = <StockBatch>[];
      final u60 = <StockBatch>[];
      final u90 = <StockBatch>[];
      for (final it in _visibleItems) {
        for (final b in it.batches) {
          final d = b.daysToExpiry;
          if (d == null) continue;
          if (d < 0) {
            expired.add(b);
          } else if (d < 30) {
            u30.add(b);
          } else if (d <= 60) {
            u60.add(b);
          } else if (d <= 90) {
            u90.add(b);
          }
        }
      }
      int byDate(StockBatch a, StockBatch b) =>
          (a.expiryDate ?? '').compareTo(b.expiryDate ?? '');
      expired.sort(byDate);
      u30.sort(byDate);
      u60.sort(byDate);
      u90.sort(byDate);
      return [expired, u30, u60, u90];
    }();
  }

  InventorySummary get _summary =>
      _cachedSummary ??= _repo.summarize(_visibleItems);

  String get _scopeName {
    if (_branchId == null) return 'All branches';
    return _branches.where((b) => b.id == _branchId).map((b) => b.name).join();
  }

  // ---- Actions ---------------------------------------------------------------

  Future<void> _adjust(StockBatch b) async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _AdjustSheet(repo: _repo, batch: b),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Stock adjusted.');
    }
  }

  Future<void> _editPrices(StockBatch b) async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _PriceSheet(repo: _repo, batch: b),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Prices updated.');
    }
  }

  Future<void> _addStock() async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _AddStockSheet(
        repo: _repo,
        branches: _branches,
        items: _catalog.where((item) => item.isActive).toList(),
      ),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Stock added and available for sale.');
    }
  }

  Future<void> _addOrEditItem([CatalogItem? item]) async {
    final msg = await showAdaptiveSheet<String>(
      context,
      builder: (_) => _ItemFormSheet(
        repo: _repo,
        item: item,
        categories: _categories,
        businessTypes: _businessTypes,
      ),
    );
    if (msg == null) return;
    await _load();
    if (mounted) showToast(context, msg);
  }

  Future<void> _toggleItemActive(CatalogItem item) async {
    if (item.isActive) {
      final ok = await showConfirm(
        context,
        title: 'Discontinue ${item.name}?',
        message: 'It stays in history and existing batches, but can\'t be ordered or sold going forward.',
        confirmLabel: 'Discontinue',
      );
      if (!ok) return;
    }
    try {
      await _repo.setItemActive(item.id, !item.isActive);
      await _load();
      if (mounted) {
        showToast(
          context,
          item.isActive
              ? '${item.name} discontinued.'
              : '${item.name} is active again.',
        );
      }
    } on InventoryException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  // ---- CSV export: downloads a .csv file onto the user's device ------------

  bool _exporting = false;

  String _exportFileName(String tab) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'chipatala_${tab}_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  Future<void> _exportCurrentTab() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final scope = _scopeName;
      late String tab;
      late String csv;
      switch (_tab) {
        case 0:
          tab = 'stock_overview';
          final buf = StringBuffer(
            'Item,Category,Unit,Branches,Qty on hand,Reorder level,Status,Stock value (MK)\n',
          );
          for (final it in _visibleItems) {
            final where = it.byBranch
                .map((e) => '${e.key} (${_fmtQty(e.value)})')
                .join('; ');
            buf.writeln(
              [
                _csvCell(it.itemName),
                _csvCell(it.category),
                _csvCell(it.unit),
                _csvCell(where),
                _fmtQty(it.qtyOnHand),
                _fmtQty(it.reorderLevel),
                it.status.name,
                it.stockValue.round(),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 1:
          tab = 'low_stock';
          final buf = StringBuffer('Item,Branch,Qty on hand,Reorder level\n');
          for (final r in _low) {
            buf.writeln(
              [
                _csvCell(r.itemName),
                _csvCell(r.branchName),
                _fmtQty(r.qtyOnHand),
                _fmtQty(r.reorderLevel),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 2:
          tab = 'expiry';
          final buf = StringBuffer(
            'Item,Batch,Branch,Expiry date,Days to expiry,Qty,Value at risk (MK)\n',
          );
          for (final bucket in _expiryBuckets()) {
            for (final b in bucket) {
              buf.writeln(
                [
                  _csvCell(b.itemName),
                  _csvCell(b.batchNumber),
                  _csvCell(b.branchName),
                  b.expiryDate ?? '',
                  b.daysToExpiry ?? '',
                  _fmtQty(b.qtyAvailable),
                  (b.qtyAvailable * b.buyingPrice).round(),
                ].join(','),
              );
            }
          }
          csv = buf.toString();
        case 3:
          tab = 'stock_movements';
          final buf = StringBuffer('Date,Type,Item,Branch,Quantity,Notes\n');
          for (final m in _visibleMovements) {
            buf.writeln(
              [
                _csvCell(m.createdAt),
                m.type,
                _csvCell(m.itemName),
                _csvCell(m.branchName),
                _fmtQty(m.quantity),
                _csvCell(m.notes ?? ''),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 4:
          tab = 'purchases';
          final buf = StringBuffer(
            'Date,Invoice,Branch,Supplier,Total (MK),Paid (MK),Balance (MK),Status\n',
          );
          for (final p in _visiblePurchases) {
            buf.writeln(
              [
                p.purchaseDate,
                _csvCell(p.invoiceNumber),
                _csvCell(p.branchName),
                _csvCell(p.supplierName),
                p.totalAmount.round(),
                p.amountPaid.round(),
                p.balance.round(),
                p.paymentStatus,
              ].join(','),
            );
          }
          csv = buf.toString();
        default:
          tab = 'item_catalog';
          final buf = StringBuffer(
            'Name,Category,Unit,Reorder level,Rx,Active\n',
          );
          for (final c in _visibleCatalog) {
            buf.writeln(
              [
                _csvCell(c.name),
                _csvCell(c.category),
                _csvCell(c.unit),
                _fmtQty(c.reorderLevel),
                c.requiresPrescription ? 'yes' : 'no',
                c.isActive ? 'yes' : 'no',
              ].join(','),
            );
          }
          csv = buf.toString();
      }
      final rows = csv.trim().split('\n').length - 1;
      final path = await saveDownload(
        name: _exportFileName(tab),
        bytes: Uint8List.fromList(utf8.encode(csv)),
        extension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) showToast(context, '$rows rows ($scope) saved to $path');
    } catch (e) {
      if (mounted) showToast(context, 'Export failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: kPrimary,
          onRefresh: _load,
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= kWideContentBreakpoint;
              final horizontalPadding = wide ? 32.0 : 18.0;
              final topPadding = wide ? 28.0 : 12.0;

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          topPadding,
                          horizontalPadding,
                          _showNeedsAttention ? 0 : 14,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_showNeedsAttention)
                                _attentionTitle()
                              else
                                PageTitle(
                                  title: 'Inventory',
                                  subtitle: _loading
                                      ? 'Loading…'
                                      : '${_visibleItems.length} items · $_scopeName',
                                  trailing: _exporting
                                      ? const SizedBox(
                                          width: 44,
                                          height: 44,
                                          child: Center(
                                            child: SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: kPrimary,
                                              ),
                                            ),
                                          ),
                                        )
                                      : OutlinedButton.icon(
                                          onPressed: _loading
                                              ? null
                                              : _exportCurrentTab,
                                          style: outlineButtonStyle(height: 44),
                                          icon: const Icon(
                                            Icons.download_outlined,
                                            size: 18,
                                          ),
                                          label: const Text('Export'),
                                        ),
                                ),
                              const SizedBox(height: 18),
                              if (!_showNeedsAttention) ...[
                                _filterBar(wide),
                                const SizedBox(height: 16),
                                _actionButtons(),
                                const SizedBox(height: 14),
                                _summaryCards(wide),
                                const SizedBox(height: 16),
                                _tabChips(),
                              ],
                            ],
                          ),
                        ),
                      ),
                      ..._buildContentSlivers(wide, horizontalPadding),
                      const SliverToBoxAdapter(child: SizedBox(height: 96)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _attentionTitle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: () => setState(() => _showNeedsAttention = false),
          tooltip: 'Back to inventory',
          icon: const Icon(Icons.arrow_back, color: kInk),
          padding: EdgeInsets.zero,
          alignment: Alignment.topLeft,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: PageTitle(
            title: 'Needs attention',
            subtitle:
                '${_low.length + _expiryBuckets().fold(0, (s, b) => s + b.length)} items requiring action',
          ),
        ),
      ],
    );
  }

  Widget _actionButtons() {
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 10,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: _loading ? null : _addStock,
            style: primaryButtonStyle(height: 42),
            icon: const Icon(Icons.add_box_outlined, size: 18),
            label: const Text('Add stock'),
          ),
          OutlinedButton.icon(
            onPressed: _loading ? null : () => _addOrEditItem(),
            style: outlineButtonStyle(height: 42),
            icon: const Icon(Icons.playlist_add_outlined, size: 18),
            label: const Text('Add catalog item'),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildContentSlivers(bool wide, double horizontalPadding) {
    if (_loading) {
      return [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: CircularProgressIndicator(color: kPrimary)),
            ),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverToBoxAdapter(
            child: ErrorState(message: _error!, onRetry: _load),
          ),
        ),
      ];
    }
    if (_showNeedsAttention) {
      return _attentionSlivers(wide, horizontalPadding);
    }
    switch (_tab) {
      case 0:
        return _overviewSlivers(wide, horizontalPadding);
      case 1:
        return _lowStockSlivers(wide, horizontalPadding);
      case 2:
        return _expirySlivers(wide, horizontalPadding);
      case 3:
        return _movementsSlivers(wide, horizontalPadding);
      case 4:
        return _purchasesSlivers(wide, horizontalPadding);
      default:
        return _catalogSlivers(wide, horizontalPadding);
    }
  }

  List<Widget> _overviewSlivers(bool wide, double horizontalPadding) {
    final items = _visibleItems;
    if (items.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No stock found',
              message: 'Try a different branch, category or search.',
            ),
          ),
        ),
      ];
    }
    return [
      if (wide)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _overviewHeader(),
            ),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverList.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            return _OverviewRow(
              key: ValueKey(items[i].itemId),
              item: items[i],
              wide: wide,
              showBranch: _branchId == null,
              onAdjust: _adjust,
              onEditPrices: _editPrices,
            );
          },
        ),
      ),
    ];
  }

  Widget _overviewHeader() {
    const style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: kInkMuted,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: const [
          Expanded(flex: 3, child: Text('ITEM', style: style)),
          Expanded(flex: 1, child: Text('ON HAND', style: style)),
          Expanded(flex: 1, child: Text('REORDER', style: style)),
          Expanded(flex: 1, child: Text('STATUS', style: style)),
          Expanded(
            flex: 1,
            child: Text('VALUE', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(width: 40),
        ],
      ),
    );
  }

  List<Widget> _lowStockSlivers(bool wide, double horizontalPadding) {
    if (_low.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.check_circle_outline,
              title: 'Stock levels are healthy',
              message:
                  'Nothing is at or below its reorder level for this filter.',
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverList.separated(
          itemCount: _low.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            return _LowStockCard(
              key: ValueKey('low_${_low[i].itemName}_${_low[i].branchName}'),
              row: _low[i],
            );
          },
        ),
      ),
    ];
  }

  List<Widget> _expirySlivers(bool wide, double horizontalPadding) {
    final buckets = _expiryBuckets();
    final total = buckets.fold(0, (s, b) => s + b.length);
    if (total == 0) {
      return [
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.check_circle_outline,
              title: 'No batches expiring soon',
              message: 'Nothing in scope expires within the next 90 days.',
            ),
          ),
        ),
      ];
    }
    const titles = [
      'Already expired',
      'Under 30 days',
      '30 to 60 days',
      '60 to 90 days',
    ];
    const subs = [
      'Write off or remove from sale.',
      'Discount or push first.',
      'Plan to move soon.',
      'Watch list.',
    ];
    final slivers = <Widget>[];
    for (int i = 0; i < buckets.length; i++) {
      final list = buckets[i];
      if (list.isEmpty) continue;
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            slivers.isEmpty ? 0 : 12,
            horizontalPadding,
            8,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${titles[i]} (${list.length})',
                  style: sans(
                    13,
                    weight: FontWeight.w700,
                    color: i == 0 ? kDanger : kInk,
                  ),
                ),
                Text(subs[i], style: sans(11.5, color: kInkMuted)),
              ],
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverList.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final b = list[idx];
              return _ExpiryBatchCard(
                key: ValueKey('exp_${b.id}'),
                batch: b,
                isExpired: i == 0,
                onAdjust: _adjust,
              );
            },
          ),
        ),
      );
    }
    return slivers;
  }

  List<Widget> _movementsSlivers(bool wide, double horizontalPadding) {
    final movements = _visibleMovements;
    final activityLabel = _activityUserId == null
        ? null
        : 'Activity: ${_activityUserName ?? 'cashier'} · ${_fmtDate(_activityFrom?.toIso8601String())} – ${_fmtDate(_activityTo?.toIso8601String())}';

    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (activityLabel != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: kPrimaryTint,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_search_outlined,
                        size: 17,
                        color: kPrimary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          activityLabel,
                          style: sans(
                            12.5,
                            weight: FontWeight.w600,
                            color: kPrimary,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _activityUserId = null;
                            _activityUserName = null;
                            _activityFrom = null;
                            _activityTo = null;
                            _invalidateFilterCaches();
                          });
                          _load();
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 16, color: kPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterPill(
                      label: 'All types',
                      selected: _movementType == null,
                      onTap: () => setState(() {
                        _movementType = null;
                        _invalidateFilterCaches();
                      }),
                    ),
                    const SizedBox(width: 8),
                    for (final t in _kMovementTypes) ...[
                      FilterPill(
                        label: _movementMeta(t).label,
                        selected: _movementType == t,
                        onTap: () => setState(() {
                          _movementType = _movementType == t ? null : t;
                          _invalidateFilterCaches();
                        }),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
      if (movements.isEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.history_outlined,
              title: 'No movements found',
              message: 'Try a different type, branch or search.',
            ),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverList.builder(
            itemCount: movements.length,
            itemBuilder: (context, i) {
              final m = movements[i];
              return _MovementItemRow(
                key: ValueKey(m.id),
                movement: m,
                isFirst: i == 0,
                isLast: i == movements.length - 1,
              );
            },
          ),
        ),
    ];
  }

  List<Widget> _purchasesSlivers(bool wide, double horizontalPadding) {
    final purchases = _visiblePurchases;
    final totalOwed = _balances.fold(0.0, (s, b) => s + b.amountOwed);

    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: kBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Owed to suppliers',
                      style: sans(
                        12.5,
                        weight: FontWeight.w600,
                        color: kInkMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MK ${_fmtMk(totalOwed)}',
                      style: mono(
                        21,
                        weight: FontWeight.w700,
                        color: totalOwed > 0 ? kDanger : kInk,
                      ),
                    ),
                    if (_balances.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final b in _balances)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  b.supplierName,
                                  style: sans(13, color: kInk),
                                ),
                              ),
                              Text(
                                'MK ${_fmtMk(b.amountOwed)}',
                                style: mono(
                                  13,
                                  weight: FontWeight.w600,
                                  color: kDanger,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ] else ...[
                      const SizedBox(height: 4),
                      Text(
                        'Nothing owed right now.',
                        style: sans(12.5, color: kInkMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Stock orders (${purchases.length})',
                style: sans(13, weight: FontWeight.w600, color: kInkMuted),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      if (purchases.isEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: 'No purchase orders',
              message: 'Orders recorded at branches will appear here.',
            ),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverList.separated(
            itemCount: purchases.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              return _PurchaseOrderCard(
                key: ValueKey(purchases[i].id),
                purchase: purchases[i],
              );
            },
          ),
        ),
    ];
  }

  List<Widget> _catalogSlivers(bool wide, double horizontalPadding) {
    final items = _visibleCatalog;
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Products (${items.length})',
                      style: sans(
                        13,
                        weight: FontWeight.w600,
                        color: kInkMuted,
                      ),
                    ),
                  ),
                  FilterPill(
                    label: _showInactive
                        ? 'Hiding discontinued'
                        : 'Show discontinued',
                    selected: _showInactive,
                    onTap: () {
                      setState(() {
                        _showInactive = !_showInactive;
                        _invalidateFilterCaches();
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _addOrEditItem(),
                    style: primaryButtonStyle(height: 40),
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('Add item'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
      if (items.isEmpty)
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.category_outlined,
              title: 'No products found',
              message: 'Try a different search or category.',
              action: FilledButton.icon(
                onPressed: () => _addOrEditItem(),
                style: primaryButtonStyle(height: 42),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Add item'),
              ),
            ),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final c = items[i];
              return _CatalogProductCard(
                key: ValueKey(c.id),
                item: c,
                onEdit: () => _addOrEditItem(c),
                onToggleActive: () => _toggleItemActive(c),
              );
            },
          ),
        ),
    ];
  }

  List<Widget> _attentionSlivers(bool wide, double horizontalPadding) {
    final buckets = _expiryBuckets();
    final expiryCount = buckets.fold(0, (s, b) => s + b.length);
    final showLow = _attentionFilter == 0 || _attentionFilter == 1;
    final showExpiry = _attentionFilter == 0 || _attentionFilter == 2;
    final slivers = <Widget>[];

    slivers.add(
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterPill(
                      label: 'All (${_low.length + expiryCount})',
                      selected: _attentionFilter == 0,
                      onTap: () => setState(() => _attentionFilter = 0),
                    ),
                    const SizedBox(width: 8),
                    FilterPill(
                      label: 'Low stock (${_low.length})',
                      selected: _attentionFilter == 1,
                      onTap: () => setState(() => _attentionFilter = 1),
                    ),
                    const SizedBox(width: 8),
                    FilterPill(
                      label: 'Expiring ($expiryCount)',
                      selected: _attentionFilter == 2,
                      onTap: () => setState(() => _attentionFilter = 2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );

    if (showLow && _low.isNotEmpty) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            10,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Low stock',
              style: sans(16, weight: FontWeight.w700, color: kInk),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            20,
          ),
          sliver: SliverList.separated(
            itemCount: _low.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              return _LowStockCard(
                key: ValueKey('low_${_low[i].itemName}_${_low[i].branchName}'),
                row: _low[i],
              );
            },
          ),
        ),
      );
    }

    if (showExpiry && expiryCount > 0) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            10,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Expiring and expired',
              style: sans(16, weight: FontWeight.w700, color: kInk),
            ),
          ),
        ),
      );
      slivers.addAll(_expirySlivers(wide, horizontalPadding));
    }

    if ((!showLow || _low.isEmpty) && (!showExpiry || expiryCount == 0)) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          sliver: const SliverToBoxAdapter(
            child: EmptyState(
              icon: Icons.check_circle_outline,
              title: 'Nothing needs attention',
              message: 'Stock levels and expiry dates are currently healthy.',
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  Widget _filterBar(bool wide) {
    final branchDropdown = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _branchId,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: kInkMuted,
          ),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          hint: Text(
            'All Branches',
            style: sans(13.5, weight: FontWeight.w500, color: kInk),
          ),
          onChanged: _onBranchChanged,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Branches'),
            ),
            ..._branches.map(
              (b) =>
                  DropdownMenuItem<String?>(value: b.id, child: Text(b.name)),
            ),
          ],
        ),
      ),
    );
    final categoryDropdown = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _category,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: kInkMuted,
          ),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          hint: Text(
            'All Categories',
            style: sans(13.5, weight: FontWeight.w500, color: kInk),
          ),
          onChanged: (v) {
            setState(() {
              _category = v;
              _invalidateFilterCaches();
            });
          },
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Categories'),
            ),
            ..._categories.map(
              (c) => DropdownMenuItem<String?>(value: c, child: Text(c)),
            ),
          ],
        ),
      ),
    );

    if (wide) {
      return Row(
        children: [
          branchDropdown,
          const SizedBox(width: 10),
          Expanded(
            child: SearchField(
              hint: 'Search item, batch or branch…',
              controller: _searchCtrl,
              onChanged: (v) {
                setState(() {
                  _search = v;
                  _invalidateFilterCaches();
                });
              },
            ),
          ),
          const SizedBox(width: 10),
          categoryDropdown,
        ],
      );
    }
    // Mobile: search + Filters button; branch/category live in a sheet.
    final activeFilters =
        (_branchId != null ? 1 : 0) + (_category != null ? 1 : 0);
    return Row(
      children: [
        Expanded(
          child: SearchField(
            hint: 'Search stock…',
            controller: _searchCtrl,
            onChanged: (v) {
              setState(() {
                _search = v;
                _invalidateFilterCaches();
              });
            },
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final res = await showAdaptiveSheet<_FilterResult>(
              context,
              builder: (_) => _FiltersSheet(
                branches: _branches,
                categories: _categories,
                branchId: _branchId,
                category: _category,
              ),
            );
            if (res != null && mounted) {
              setState(() {
                _branchId = res.branchId;
                _category = res.category;
                _invalidateFilterCaches();
              });
              if (res.branchChanged) await _load();
            }
          },
          style: outlineButtonStyle(height: 46),
          icon: Badge(
            isLabelVisible: activeFilters > 0,
            label: Text('$activeFilters'),
            child: const Icon(Icons.tune_outlined, size: 18),
          ),
          label: const Text('Filters'),
        ),
      ],
    );
  }

  Widget _summaryCards(bool wide) {
    final s = _summary;
    final cards = [
      _SummaryCard(
        label: 'Stock value (cost)',
        value: 'MK ${_fmtMk(s.stockValue)}',
        sub: 'capital tied up',
        icon: Icons.inventory_2_outlined,
      ),
      _SummaryCard(
        label: 'Expected revenue',
        value: 'MK ${_fmtMk(s.sellingValue)}',
        sub: 'at retail selling price',
        icon: Icons.point_of_sale_outlined,
      ),
      _SummaryCard(
        label: 'Potential profit',
        value: 'MK ${_fmtMk(s.potentialProfit)}',
        sub: 'revenue minus cost',
        icon: Icons.trending_up_outlined,
      ),
    ];
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i != cards.length - 1) const SizedBox(width: 12),
          ],
        ],
      );
    }
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(width: 168, child: cards[i]),
      ),
    );
  }

  Widget _tabChips() {
    final buckets = _expiryBuckets();
    final expiryCount = buckets.fold(0, (s, b) => s + b.length);
    final labels = [
      'Overview',
      'Low stock (${_low.length})',
      'Expiry ($expiryCount)',
      'Movements',
      'Purchases (${_purchases.length})',
      'Catalog (${_catalog.where((c) => c.isActive).length})',
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < _kTabs.length; i++) ...[
            FilterPill(
              label: labels[i],
              selected: _tab == i,
              onTap: () => setState(() => _tab = i),
            ),
            if (i != _kTabs.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// SUMMARY CARD
// ============================================================================

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.toUpperCase(),
                style: sans(
                  10,
                  weight: FontWeight.w700,
                  color: kInkMuted,
                ).copyWith(letterSpacing: 0.5),
              ),
              Icon(icon, size: 15, color: kInkMuted),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: mono(18, weight: FontWeight.w700, color: kInk),
          ),
          const SizedBox(height: 2),
          Text(sub, style: sans(11, color: kInkMuted)),
        ],
      ),
    );
  }
}

// ============================================================================
// TAB 0 — STOCK OVERVIEW (expandable batches)
// ============================================================================

class _OverviewRow extends StatelessWidget {
  final ItemStock item;
  final bool wide;
  final bool showBranch;
  final ValueChanged<StockBatch> onAdjust;
  final ValueChanged<StockBatch> onEditPrices;
  const _OverviewRow({
    super.key,
    required this.item,
    required this.wide,
    required this.showBranch,
    required this.onAdjust,
    required this.onEditPrices,
  });

  @override
  Widget build(BuildContext context) {
    final where = item.byBranch
        .take(2)
        .map((e) => '${e.key} (${_fmtQty(e.value)})')
        .join(' · ');
    final extra = item.byBranch.length > 2
        ? ' +${item.byBranch.length - 2} more'
        : '';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        title: wide
            ? Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.itemName,
                          style: sans(
                            13.5,
                            weight: FontWeight.w600,
                            color: kInk,
                          ),
                        ),
                        Text(
                          '${item.category} · ${item.unit}${showBranch ? ' · $where$extra' : ''}',
                          style: sans(11.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text(
                      _fmtQty(item.qtyOnHand),
                      style: mono(13.5, weight: FontWeight.w600, color: kInk),
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text(
                      _fmtQty(item.reorderLevel),
                      style: sans(13, color: kInkMuted),
                    ),
                  ),
                  Expanded(flex: 1, child: _StatusChip(status: item.status)),
                  Expanded(
                    flex: 1,
                    child: Text(
                      'MK ${_fmtMk(item.stockValue)}',
                      style: mono(12.5, weight: FontWeight.w600, color: kInk),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.itemName,
                          style: sans(
                            13.5,
                            weight: FontWeight.w600,
                            color: kInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_fmtQty(item.qtyOnHand)} ${item.unit} · $where$extra',
                          style: sans(11.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(status: item.status),
                ],
              ),
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(
              children: [
                for (int i = 0; i < item.batches.length; i++)
                  _BatchRow(
                    batch: item.batches[i],
                    unit: item.unit,
                    last: i == item.batches.length - 1,
                    onAdjust: onAdjust,
                    onEditPrices: onEditPrices,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final StockStatus status;
  const _StatusChip({required this.status});
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case StockStatus.out:
        return const StatusPill(label: 'Out', bg: kDangerTint, fg: kDanger);
      case StockStatus.low:
        return const StatusPill(label: 'Low', bg: kWarnTint, fg: kWarn);
      case StockStatus.ok:
        return const StatusPill(label: 'OK', bg: kSuccessTint, fg: kSuccess);
    }
  }
}

class _BatchRow extends StatelessWidget {
  final StockBatch batch;
  final String unit;
  final bool last;
  final ValueChanged<StockBatch> onAdjust;
  final ValueChanged<StockBatch> onEditPrices;
  const _BatchRow({
    required this.batch,
    required this.unit,
    required this.last,
    required this.onAdjust,
    required this.onEditPrices,
  });

  @override
  Widget build(BuildContext context) {
    final d = batch.daysToExpiry;
    final expiryLabel = batch.expiryDate == null
        ? 'No expiry'
        : d == null
        ? _fmtDate(batch.expiryDate)
        : d < 0
        ? 'Expired ${_fmtDate(batch.expiryDate)}'
        : 'Exp $d d · ${_fmtDate(batch.expiryDate)}';
    final expiryColor = batch.isExpired
        ? kDanger
        : (d != null && d <= 30 ? kWarn : kInkMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kBg,
        border: last ? null : const Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch ${batch.batchNumber} · ${batch.branchName}',
                  style: sans(12.5, weight: FontWeight.w600, color: kInk),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtQty(batch.qtyAvailable)} $unit · Buy MK ${_fmtMk(batch.buyingPrice)} · Sell MK ${_fmtMk(batch.retailPrice)}',
                  style: sans(11.5, color: kInkMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  expiryLabel,
                  style: sans(
                    11.5,
                    weight: FontWeight.w600,
                    color: expiryColor,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18, color: kInkMuted),
            color: Colors.white,
            onSelected: (v) {
              if (v == 'adjust') {
                onAdjust(batch);
              } else {
                onEditPrices(batch);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'adjust', child: Text('Adjust stock')),
              PopupMenuItem(value: 'prices', child: Text('Change prices')),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ============================================================================
// ITEM CARDS (virtualized sliver list rows)
// ============================================================================

class _LowStockCard extends StatelessWidget {
  final LowStockRow row;
  const _LowStockCard({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.itemName,
                      style: sans(13.5, weight: FontWeight.w600, color: kInk),
                    ),
                    const SizedBox(height: 2),
                    Text(row.branchName, style: sans(12, color: kInkMuted)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${_fmtQty(row.qtyOnHand)} / ${_fmtQty(row.reorderLevel)}',
                    style: mono(13, weight: FontWeight.w700, color: kWarn),
                  ),
                  Text(
                    'on hand / reorder',
                    style: sans(10.5, color: kInkMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: row.severity,
              minHeight: 5,
              backgroundColor: kWarnTint,
              valueColor: const AlwaysStoppedAnimation<Color>(kWarn),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpiryBatchCard extends StatelessWidget {
  final StockBatch batch;
  final bool isExpired;
  final ValueChanged<StockBatch> onAdjust;
  const _ExpiryBatchCard({
    super.key,
    required this.batch,
    required this.isExpired,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  batch.itemName,
                  style: sans(13.5, weight: FontWeight.w600, color: kInk),
                ),
                const SizedBox(height: 2),
                Text(
                  'Batch ${batch.batchNumber} · ${batch.branchName} · ${_fmtDate(batch.expiryDate)} '
                  '(${batch.daysToExpiry != null && batch.daysToExpiry! < 0 ? '${-batch.daysToExpiry!}d overdue' : '${batch.daysToExpiry ?? 0}d left'})',
                  style: sans(11.5, color: kInkMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtQty(batch.qtyAvailable)} on hand · MK ${_fmtMk(batch.qtyAvailable * batch.buyingPrice)} at risk',
                  style: sans(
                    11.5,
                    weight: FontWeight.w600,
                    color: isExpired ? kDanger : kWarn,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onAdjust(batch),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Write off',
              style: sans(12.5, weight: FontWeight.w600, color: kPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementItemRow extends StatelessWidget {
  final StockMovement movement;
  final bool isFirst;
  final bool isLast;
  const _MovementItemRow({
    super.key,
    required this.movement,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final meta = _movementMeta(movement.type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          left: const BorderSide(color: kBorder),
          right: const BorderSide(color: kBorder),
          top: isFirst ? const BorderSide(color: kBorder) : BorderSide.none,
          bottom: const BorderSide(color: kBorder),
        ),
        borderRadius: BorderRadius.vertical(
          top: isFirst ? const Radius.circular(4) : Radius.zero,
          bottom: isLast ? const Radius.circular(4) : Radius.zero,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(meta.icon, size: 18, color: meta.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  movement.itemName,
                  style: sans(13, weight: FontWeight.w600, color: kInk),
                ),
                const SizedBox(height: 2),
                Text(
                  '${movement.branchName} · ${meta.label} · ${_fmtDateTime(movement.createdAt)}${movement.performedByName != null && movement.performedByName!.trim().isNotEmpty ? ' · by ${movement.performedByName!.trim()}' : ''}',
                  style: sans(11.5, color: kInkMuted),
                ),
                if ((movement.notes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '“${movement.notes!.trim()}”',
                    style: sans(11.5, color: kInkMuted, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${meta.isOut ? '−' : '+'}${_fmtQty(movement.quantity)}',
            style: mono(13, weight: FontWeight.w700, color: meta.color),
          ),
        ],
      ),
    );
  }
}

class _PurchaseOrderCard extends StatelessWidget {
  final PurchaseOrder purchase;
  const _PurchaseOrderCard({super.key, required this.purchase});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  purchase.invoiceNumber == '—'
                      ? purchase.supplierName
                      : '${purchase.supplierName} · ${purchase.invoiceNumber}',
                  style: sans(13.5, weight: FontWeight.w600, color: kInk),
                ),
              ),
              _PaymentPill(status: purchase.paymentStatus),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${purchase.branchName} · ${_fmtDate(purchase.purchaseDate)} · ${purchase.lineCount} ${purchase.lineCount == 1 ? 'line' : 'lines'}',
            style: sans(12, color: kInkMuted),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'MK ${_fmtMk(purchase.totalAmount)}',
                style: mono(14, weight: FontWeight.w700, color: kInk),
              ),
              const SizedBox(width: 10),
              Text(
                'paid MK ${_fmtMk(purchase.amountPaid)}',
                style: sans(12, color: kInkMuted),
              ),
              const Spacer(),
              if (purchase.balance > 0)
                Text(
                  'owes MK ${_fmtMk(purchase.balance)}',
                  style: sans(12, weight: FontWeight.w700, color: kDanger),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PaymentPill extends StatelessWidget {
  final String status;
  const _PaymentPill({super.key, required this.status});
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'paid':
        return const StatusPill(label: 'Paid', bg: kSuccessTint, fg: kSuccess);
      case 'partial':
        return const StatusPill(label: 'Partial', bg: kWarnTint, fg: kWarn);
      default:
        return const StatusPill(label: 'Pending', bg: kDangerTint, fg: kDanger);
    }
  }
}

class _CatalogProductCard extends StatelessWidget {
  final CatalogItem item;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  const _CatalogProductCard({
    super.key,
    required this.item,
    required this.onEdit,
    required this.onToggleActive,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        style: sans(
                          13.5,
                          weight: FontWeight.w600,
                          color: item.isActive ? kInk : kInkMuted,
                        ),
                      ),
                    ),
                    if (item.requiresPrescription) ...[
                      const SizedBox(width: 6),
                      const StatusPill(
                        label: 'Rx',
                        bg: kPrimaryTint,
                        fg: kPrimary,
                      ),
                    ],
                    if (!item.isActive) ...[
                      const SizedBox(width: 6),
                      const StatusPill(
                        label: 'Stopped',
                        bg: kSurface,
                        fg: kInkMuted,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.businessTypeName} · ${item.category} · ${item.unit}${item.quantityStep != 1 ? ' · step ${fmtQty(item.quantityStep)}' : ''}${item.units.isNotEmpty ? ' · extra: ${item.units.map((u) => '${u.name} (${fmtQty(u.factor)})').join(', ')}' : ''} · reorder at ${_fmtQty(item.reorderLevel)}',
                  style: sans(11.5, color: kInkMuted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18, color: kInkMuted),
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
          Switch(
            value: item.isActive,
            activeThumbColor: kPrimary,
            onChanged: (_) => onToggleActive(),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// FILTERS SHEET (mobile)
// ============================================================================

class _FilterResult {
  final String? branchId;
  final String? category;
  final bool branchChanged;
  const _FilterResult({
    required this.branchId,
    required this.category,
    required this.branchChanged,
  });
}

class _FiltersSheet extends StatefulWidget {
  final List<InvBranch> branches;
  final List<String> categories;
  final String? branchId;
  final String? category;
  const _FiltersSheet({
    required this.branches,
    required this.categories,
    required this.branchId,
    required this.category,
  });

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late String? _branchId = widget.branchId;
  late String? _category = widget.category;

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Filters',
      subtitle: 'Scope the whole inventory section.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Branch',
            style: sans(13, weight: FontWeight.w600, color: kInkMuted),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: [
                RadioListTile<String?>(
                  value: null,
                  groupValue: _branchId,
                  onChanged: (v) => setState(() => _branchId = v),
                  title: Text('All Branches', style: sans(13.5, color: kInk)),
                  activeColor: kPrimary,
                  dense: true,
                ),
                for (final b in widget.branches)
                  RadioListTile<String?>(
                    value: b.id,
                    groupValue: _branchId,
                    onChanged: (v) => setState(() => _branchId = v),
                    title: Text(b.name, style: sans(13.5, color: kInk)),
                    activeColor: kPrimary,
                    dense: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Category',
            style: sans(13, weight: FontWeight.w600, color: kInkMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterPill(
                label: 'All',
                selected: _category == null,
                onTap: () => setState(() => _category = null),
              ),
              for (final c in widget.categories)
                FilterPill(
                  label: c,
                  selected: _category == c,
                  onTap: () =>
                      setState(() => _category = _category == c ? null : c),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _branchId = null;
                    _category = null;
                  }),
                  style: outlineButtonStyle(),
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    _FilterResult(
                      branchId: _branchId,
                      category: _category,
                      branchChanged: _branchId != widget.branchId,
                    ),
                  ),
                  style: primaryButtonStyle(),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ADD STOCK SHEET — creates one sellable batch for a selected branch
// ============================================================================

class _AddStockSheet extends StatefulWidget {
  final InventoryRepository repo;
  final List<InvBranch> branches;
  final List<CatalogItem> items;

  const _AddStockSheet({
    required this.repo,
    required this.branches,
    required this.items,
  });

  @override
  State<_AddStockSheet> createState() => _AddStockSheetState();
}

class _AddStockSheetState extends State<_AddStockSheet> {
  final _quantityCtrl = TextEditingController();
  final _buyingCtrl = TextEditingController();
  final _retailCtrl = TextEditingController();
  final _wholesaleCtrl = TextEditingController();
  final _batchCtrl = TextEditingController();
  String? _branchId;
  String? _itemId;
  String? _selectedUnit;
  DateTime? _expiryDate;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _buyingCtrl.dispose();
    _retailCtrl.dispose();
    _wholesaleCtrl.dispose();
    _batchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: _expiryDate ?? DateTime.now(),
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  Future<void> _submit() async {
    final quantity = double.tryParse(_quantityCtrl.text.trim());
    final buying = double.tryParse(_buyingCtrl.text.trim());
    final retail = double.tryParse(_retailCtrl.text.trim());
    final wholesale = _wholesaleCtrl.text.trim().isEmpty
        ? null
        : double.tryParse(_wholesaleCtrl.text.trim());
    if (_branchId == null || _itemId == null) {
      setState(() => _error = 'Choose a branch and item.');
      return;
    }
    if (quantity == null || buying == null || retail == null || quantity <= 0) {
      setState(() => _error = 'Enter a valid quantity and prices.');
      return;
    }
    if (wholesale == null && _wholesaleCtrl.text.trim().isNotEmpty) {
      setState(
        () => _error = 'Enter a valid wholesale price or leave it empty.',
      );
      return;
    }

    final selectedItem = widget.items.cast<CatalogItem?>().firstWhere(
      (it) => it?.id == _itemId,
      orElse: () => null,
    );
    final unitName = _selectedUnit ?? selectedItem?.unit ?? 'unit';
    final factor = selectedItem == null
        ? 1.0
        : factorFor(unitName, selectedItem.unit, selectedItem.units);
    final baseQty = roundQty(quantity * factor);
    final baseBuy = pricePerBase(buying, factor) ?? (buying / factor);
    final baseRetail = pricePerBase(retail, factor) ?? (retail / factor);
    final baseWhole = wholesale != null
        ? (pricePerBase(wholesale, factor) ?? (wholesale / factor))
        : null;

    if (selectedItem != null && !onStep(baseQty, selectedItem.quantityStep)) {
      setState(
        () => _error =
            'Quantity in ${selectedItem.unit} must be a multiple of ${fmtQty(selectedItem.quantityStep)}.',
      );
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.addStock(
        branchId: _branchId!,
        itemId: _itemId!,
        quantity: baseQty,
        buyingPrice: baseBuy,
        retailPrice: baseRetail,
        wholesalePrice: baseWhole,
        batchNumber: _batchCtrl.text,
        expiryDate: _expiryDate,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Add stock',
      subtitle: 'The new batch will be available for sale immediately.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _branchId,
            decoration: fieldDecoration('Branch'),
            items: widget.branches
                .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                .toList(),
            onChanged: _saving
                ? null
                : (value) => setState(() => _branchId = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _itemId,
            decoration: fieldDecoration('Item'),
            items: widget.items
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} · ${item.unit}'),
                  ),
                )
                .toList(),
            onChanged: _saving
                ? null
                : (value) {
                    final it = widget.items.cast<CatalogItem?>().firstWhere(
                      (i) => i?.id == value,
                      orElse: () => null,
                    );
                    setState(() {
                      _itemId = value;
                      _selectedUnit = it?.unit;
                    });
                  },
          ),
          if (_itemId != null) ...[
            Builder(
              builder: (context) {
                final it = widget.items.cast<CatalogItem?>().firstWhere(
                  (i) => i?.id == _itemId,
                  orElse: () => null,
                );
                if (it == null || it.units.isEmpty)
                  return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedUnit ?? it.unit,
                    decoration: fieldDecoration('Receiving unit'),
                    items: [
                      DropdownMenuItem(
                        value: it.unit,
                        child: Text('${it.unit} (base unit)'),
                      ),
                      for (final u in it.units)
                        DropdownMenuItem(
                          value: u.name,
                          child: Text(
                            '${u.name} (= ${fmtQty(u.factor)} ${it.unit})',
                          ),
                        ),
                    ],
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _selectedUnit = v),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _quantityCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Quantity'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _batchCtrl,
                  decoration: fieldDecoration('Batch number', hint: 'Optional'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _buyingCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Buying price'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _retailCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Selling price'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _wholesaleCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: fieldDecoration('Wholesale price', hint: 'Optional'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _saving ? null : _pickExpiry,
            style: outlineButtonStyle(),
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(
              _expiryDate == null
                  ? 'Expiry date (optional)'
                  : _fmtDate(_expiryDate!.toIso8601String()),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Add sellable stock'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ADJUST SHEET — damage / loss / corrections, reason always recorded
// ============================================================================

class _AdjustSheet extends StatefulWidget {
  final InventoryRepository repo;
  final StockBatch batch;
  const _AdjustSheet({required this.repo, required this.batch});

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  bool _removing = true;
  final _qtyCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _formError = 'Enter a quantity above zero.');
      return;
    }
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(
        () => _formError =
            'A reason is required — it goes into the movement log.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.adjustStock(
        inventoryId: widget.batch.id,
        branchId: widget.batch.branchId,
        itemId: widget.batch.itemId,
        deltaQty: _removing ? -qty : qty,
        reason: _reasonCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.batch;
    return SheetFrame(
      title: 'Adjust stock',
      subtitle: '${b.itemName} · Batch ${b.batchNumber} · ${b.branchName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              '${_fmtQty(b.qtyAvailable)} on hand',
              style: mono(14, weight: FontWeight.w700, color: kInk),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilterPill(
                label: 'Remove',
                selected: _removing,
                onTap: () => setState(() => _removing = true),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: 'Add back',
                selected: !_removing,
                onTap: () => setState(() => _removing = false),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _qtyCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration(
              _removing ? 'Quantity to remove' : 'Quantity to add back',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonCtrl,
            style: sans(14, color: kInk),
            minLines: 2,
            maxLines: 3,
            decoration: fieldDecoration(
              'Reason',
              hint: 'e.g. 3 bottles broken in transit',
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save adjustment'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PRICE SHEET — change batch prices
// ============================================================================

class _PriceSheet extends StatefulWidget {
  final InventoryRepository repo;
  final StockBatch batch;
  const _PriceSheet({required this.repo, required this.batch});

  @override
  State<_PriceSheet> createState() => _PriceSheetState();
}

class _PriceSheetState extends State<_PriceSheet> {
  late final TextEditingController _buy = TextEditingController(
    text: fmtQty(widget.batch.buyingPrice),
  );
  late final TextEditingController _retail = TextEditingController(
    text: fmtQty(widget.batch.retailPrice),
  );
  late final TextEditingController _whole = TextEditingController(
    text: widget.batch.wholesalePrice != null
        ? fmtQty(widget.batch.wholesalePrice!)
        : '',
  );
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _buy.dispose();
    _retail.dispose();
    _whole.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final buy = double.tryParse(_buy.text.trim());
    final retail = double.tryParse(_retail.text.trim());
    final whole = _whole.text.trim().isEmpty
        ? null
        : double.tryParse(_whole.text.trim());
    if (buy == null ||
        buy < 0 ||
        retail == null ||
        retail < 0 ||
        (_whole.text.trim().isNotEmpty && whole == null)) {
      setState(() => _formError = 'Enter valid prices (zero or above).');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.updateBatchPrices(
        inventoryId: widget.batch.id,
        buyingPrice: buy,
        retailPrice: retail,
        wholesalePrice: whole,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.batch;
    return SheetFrame(
      title: 'Change prices',
      subtitle: '${b.itemName} · Batch ${b.batchNumber} · ${b.branchName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _buy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Buying price (MK)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _retail,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Retail price (MK)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _whole,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration(
              'Wholesale price (MK)',
              hint: 'Optional',
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save prices'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ITEM FORM SHEET — add / edit catalog product
// ============================================================================

class _ItemFormSheet extends StatefulWidget {
  final InventoryRepository repo;
  final CatalogItem? item;
  final List<String> categories;
  final List<BusinessTypeOption> businessTypes;
  const _ItemFormSheet({
    required this.repo,
    this.item,
    required this.categories,
    this.businessTypes = const [],
  });

  @override
  State<_ItemFormSheet> createState() => _ItemFormSheetState();
}

class _ItemFormSheetState extends State<_ItemFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.item?.name ?? '',
  );
  late final TextEditingController _category = TextEditingController(
    text: widget.item?.category == 'Uncategorised'
        ? ''
        : (widget.item?.category ?? ''),
  );
  late final TextEditingController _unit = TextEditingController(
    text: widget.item?.unit ?? 'unit',
  );
  late final TextEditingController _reorder = TextEditingController(
    text: fmtQty(widget.item?.reorderLevel ?? 10),
  );
  late final TextEditingController _step = TextEditingController(
    text: fmtQty(widget.item?.quantityStep ?? 1),
  );
  late bool _rx = widget.item?.requiresPrescription ?? false;
  late List<BusinessTypeOption> _types = List.from(widget.businessTypes);
  String? _businessTypeId;

  // Extra units (bottle, box, kg...) — each row is name + factor (how many
  // base units one of these contains).
  late final List<_UnitRowForm> _unitRows = [
    if (widget.item != null)
      for (final u in widget.item!.units)
        _UnitRowForm(
          nameCtrl: TextEditingController(text: u.name),
          factorCtrl: TextEditingController(text: fmtQty(u.factor)),
        ),
  ];

  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    if (widget.item != null && widget.item!.businessTypeId.isNotEmpty) {
      _businessTypeId = widget.item!.businessTypeId;
    } else if (_types.isNotEmpty) {
      _businessTypeId = _types.first.id;
    }
    if (_types.isEmpty) {
      _loadTypes();
    }
  }

  Future<void> _loadTypes() async {
    try {
      final t = await widget.repo.fetchBusinessTypes();
      if (!mounted) return;
      setState(() {
        _types = t;
        if (_businessTypeId == null && _types.isNotEmpty) {
          _businessTypeId = _types.first.id;
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _unit.dispose();
    _reorder.dispose();
    _step.dispose();
    for (final r in _unitRows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final reorder = double.tryParse(_reorder.text.trim());
    if (_name.text.trim().isEmpty) {
      setState(() => _formError = 'Item name is required.');
      return;
    }
    if (_businessTypeId == null || _businessTypeId!.isEmpty) {
      setState(() => _formError = 'Please select a business type.');
      return;
    }
    if (reorder == null || reorder < 0) {
      setState(() => _formError = 'Reorder level must be zero or above.');
      return;
    }
    final step = double.tryParse(_step.text.trim());
    if (step == null || step <= 0) {
      setState(() => _formError = 'Smallest sale step must be above zero.');
      return;
    }
    // Validate extra units: each needs a name and factor > 0, no duplicates,
    // and none may equal the base unit.
    final units = <QtyUnit>[];
    final seen = <String>{};
    final baseUnit = _unit.text.trim().isEmpty ? 'unit' : _unit.text.trim();
    for (final r in _unitRows) {
      final n = r.nameCtrl.text.trim();
      final f = double.tryParse(r.factorCtrl.text.trim());
      if (n.isEmpty && r.factorCtrl.text.trim().isEmpty) continue;
      if (n.isEmpty || f == null || f <= 0) {
        setState(
          () => _formError =
              'Each extra unit needs a name and a number above zero.',
        );
        return;
      }
      if (n.toLowerCase() == baseUnit.toLowerCase() ||
          !seen.add(n.toLowerCase())) {
        setState(
          () => _formError = '"$n" is repeated or equals the base unit.',
        );
        return;
      }
      units.add(QtyUnit(n, f));
    }
    // Duplicate guard: same name (case-insensitive) already catalogued.
    // Same unit means it is the same item — blocked, no override.
    // Different unit may legitimately be a separate product (bottle vs
    // tablets), so that case only warns and lets the user confirm.
    // Advisory only: a failed lookup must not block the save.
    try {
      final matches = await widget.repo.findItemsByName(_name.text);
      if (widget.item != null) {
        matches.removeWhere((c) => c.id == widget.item!.id);
      }
      if (matches.isNotEmpty && mounted) {
        final enteredUnit = _unit.text.trim().isEmpty
            ? 'unit'
            : _unit.text.trim();
        final sameUnit = matches
            .where(
              (c) => c.unit.trim().toLowerCase() == enteredUnit.toLowerCase(),
            )
            .toList();
        if (sameUnit.isNotEmpty) {
          final listed = sameUnit
              .take(3)
              .map(
                (c) => '• ${c.name} (unit: ${c.unit} · ${c.businessTypeName})',
              )
              .join('\n');
          setState(
            () => _formError =
                '“${_name.text.trim()}” is already in the catalog with the same unit ($enteredUnit):\n$listed\nThat is the same item — pick it from the catalog instead of adding it again.',
          );
          return;
        }
        final listed = matches
            .take(5)
            .map((c) => '• ${c.name} (unit: ${c.unit} · ${c.businessTypeName})')
            .join('\n');
        final proceed = await showConfirm(
          context,
          title: 'Same name, different unit',
          message:
              '“${_name.text.trim()}” is already in the catalog with a different unit:\n$listed\n\nYou entered unit “$enteredUnit”. The same product sold in a different unit counts as a separate product — continue only if that is what you mean.',
          confirmLabel: 'Add anyway',
        );
        if (!proceed) return;
      }
    } catch (_) {
      // Fall through to the save below.
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      String itemId;
      if (widget.item == null) {
        itemId = await widget.repo.createItem(
          name: _name.text,
          category: _category.text,
          unit: _unit.text,
          reorderLevel: reorder,
          requiresPrescription: _rx,
          businessTypeId: _businessTypeId!,
          quantityStep: step,
        );
      } else {
        itemId = widget.item!.id;
        await widget.repo.updateItem(
          id: itemId,
          name: _name.text,
          category: _category.text,
          unit: _unit.text,
          reorderLevel: reorder,
          requiresPrescription: _rx,
          businessTypeId: _businessTypeId!,
          quantityStep: step,
        );
      }
      await widget.repo.saveItemUnits(itemId, units);
      if (mounted) {
        Navigator.of(context)
            .pop(widget.item == null ? 'Item added.' : 'Item updated.');
      }
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: widget.item == null ? 'Add item' : 'Edit item',
      subtitle: widget.item == null
          ? 'New product in the catalog.'
          : widget.item!.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Item name'),
          ),
          const SizedBox(height: 12),
          if (_types.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              value: _businessTypeId,
              decoration: fieldDecoration('Business type'),
              style: sans(14, color: kInk),
              items: [
                for (final bt in _types)
                  DropdownMenuItem(
                    value: bt.id,
                    child: Text(bt.name, style: sans(14, color: kInk)),
                  ),
              ],
              onChanged: (v) => setState(() => _businessTypeId = v),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _category,
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Category', hint: 'e.g. Antibiotics'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _unit,
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration('Unit', hint: 'tablet, bottle…'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _reorder,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration('Reorder level'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _step,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration(
                    'Smallest sale step',
                    hint: 'e.g. 1, 0.5, 0.25',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Cashiers can only sell in multiples of this many base units.',
                  style: sans(11.5, color: kInkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _rx,
            onChanged: (v) => setState(() => _rx = v),
            title: Text(
              'Requires prescription',
              style: sans(13.5, color: kInk),
            ),
            activeThumbColor: kPrimary,
            contentPadding: EdgeInsets.zero,
          ),
          // ---- Extra units (bottle, box, kg...) ----
          if (_unitRows.isNotEmpty || widget.item == null) ...[
            const SizedBox(height: 12),
            Text(
              'Extra units (optional)',
              style: sans(13, weight: FontWeight.w600, color: kInk),
            ),
            const SizedBox(height: 4),
            Text(
              'Bigger units cashiers can pick instead of the base unit.',
              style: sans(11.5, color: kInkMuted),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _unitRows.length; i++) ...[
              _unitRowWidget(i, _unitRows[i]),
              const SizedBox(height: 8),
            ],
            OutlinedButton.icon(
              onPressed: () => setState(() => _unitRows.add(_UnitRowForm())),
              style: outlineButtonStyle(height: 40),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add unit'),
            ),
          ],
          if (widget.item != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: kBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Need to split existing stock into a smaller unit?',
                    style: sans(12.5, weight: FontWeight.w600, color: kInk),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'e.g. bottle to ml, or kg to g. Existing batches and prices convert automatically.',
                    style: sans(11.5, color: kInkMuted),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _promptConvertUnit,
                    style: outlineButtonStyle(height: 36),
                    icon: const Icon(Icons.transform, size: 15),
                    label: const Text('Convert base unit'),
                  ),
                ],
              ),
            ),
          ],
          if (_formError != null) ...[
            const SizedBox(height: 6),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(widget.item == null ? 'Add item' : 'Save changes'),
          ),
        ],
      ),
    );
  }

  Widget _unitRowWidget(int i, _UnitRowForm r) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: r.nameCtrl,
            style: sans(13.5, color: kInk),
            decoration: fieldDecoration('Unit name', hint: 'bottle, box, kg'),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 100,
          child: TextField(
            controller: r.factorCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(13.5, color: kInk),
            decoration: fieldDecoration('= base units'),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: kInkMuted),
          onPressed: () => setState(() {
            r.dispose();
            _unitRows.removeAt(i);
          }),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Future<void> _promptConvertUnit() async {
    final item = widget.item;
    if (item == null) return;
    final newUnitCtrl = TextEditingController();
    final factorCtrl = TextEditingController(text: '100');
    final stepCtrl = TextEditingController(text: '1');
    String? error;

    await showAdaptiveSheet<bool>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return SheetFrame(
            title: 'Convert base unit',
            subtitle:
                'Splits "${item.name}" into a smaller unit. Existing stock and prices will adjust automatically.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Current unit: ${item.unit}',
                  style: sans(13, weight: FontWeight.w600, color: kInk),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newUnitCtrl,
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration(
                    'New base unit name',
                    hint: 'e.g. ml, g, tablet',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: factorCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration(
                    'How many new units in 1 ${item.unit}?',
                    hint: 'e.g. 100 for 100ml bottle, 1000 for 1kg',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: stepCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration(
                    'Smallest sale step in new units',
                    hint: 'e.g. 1, 0.5, 10',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: sans(12.5, weight: FontWeight.w600, color: kDanger),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    final nu = newUnitCtrl.text.trim();
                    final factor = double.tryParse(factorCtrl.text.trim());
                    final step = double.tryParse(stepCtrl.text.trim());
                    if (nu.isEmpty) {
                      setDlg(() => error = 'Enter the new base unit name.');
                      return;
                    }
                    if (factor == null || factor <= 0) {
                      setDlg(
                        () => error =
                            'Conversion factor must be greater than zero.',
                      );
                      return;
                    }
                    if (step == null || step <= 0) {
                      setDlg(
                        () => error = 'Sale step must be greater than zero.',
                      );
                      return;
                    }
                    try {
                      await widget.repo.convertItemUnit(
                        itemId: item.id,
                        newUnit: nu,
                        factor: factor,
                        step: step,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                      if (mounted)
                        Navigator.of(context).pop('Item converted to $nu.');
                    } on InventoryException catch (e) {
                      setDlg(() => error = e.message);
                    } catch (e) {
                      setDlg(() => error = e.toString());
                    }
                  },
                  style: primaryButtonStyle(),
                  child: const Text('Convert unit and stock'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One editable row in the "Extra units" list of the item form.
class _UnitRowForm {
  final TextEditingController nameCtrl;
  final TextEditingController factorCtrl;
  _UnitRowForm({
    TextEditingController? nameCtrl,
    TextEditingController? factorCtrl,
  }) : nameCtrl = nameCtrl ?? TextEditingController(),
       factorCtrl = factorCtrl ?? TextEditingController();

  void dispose() {
    nameCtrl.dispose();
    factorCtrl.dispose();
  }
}
