import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeUi.dart';
import 'stockRepo.dart';

// ============================================================================
// CASHIER STOCK — own-branch stock list + receiving deliveries.
//   Receiving needs stock access (admin grant); without it the screen is
//   read-only with a "Request access" path. Clean, minimal presentation.
// ============================================================================

class StockScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const StockScreen({super.key, required this.user, required this.branchName});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  final _repo = CashierStockRepository();
  final _searchCtrl = TextEditingController();
  final _catalogSearchCtrl = TextEditingController();
  final _scrollController = ScrollController();

  bool _loading = true;
  String? _error;
  List<BranchStockRow> _rows = [];
  List<CatalogItemEntry> _catalog = [];
  String _query = '';
  String _catalogQuery = '';
  String _chip = 'all'; // all | low | expiring | catalog
  bool _showBackToTop = false;
  bool _showCatalogSearch = false;

  bool _canReceive = false;
  OwnAccess _access = const OwnAccess(state: OwnAccessState.none);

  // Catalog: same request -> approve -> add model as stock access.
  // A new product is visible to every branch running its business type.
  bool _canAddCatalog = false;
  OwnAccess _catalogAccess = const OwnAccess(state: OwnAccessState.none);
  List<BusinessTypeOption> _branchTypes = [];

  bool _loadedOnce = false;
  bool _wasSelected = false;

  String? get _branchId => widget.user.branchId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  void _onScroll() {
    final show = _scrollController.hasClients && _scrollController.offset > 240;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchCtrl.dispose();
    _catalogSearchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 2;
    if (selected && !_wasSelected) {
      if (_loadedOnce) {
        _load(silent: true);
      }
    }
    _wasSelected = selected;
  }

  Future<void> _load({bool silent = false}) async {
    final bid = _branchId;
    if (bid == null) {
      setState(() {
        _loading = false;
        _error = 'No branch assigned to this account yet.';
      });
      return;
    }
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        _repo.fetchStock(branchId: bid, query: _query),
        _repo.hasAccess(),
        _repo.myStatus(),
        _repo.hasCatalogAccess(),
        _repo.myCatalogStatus(),
        _repo.fetchBranchBusinessTypes(bid),
        _repo.fetchCatalogList(query: _catalogQuery),
      ]);
      if (!mounted) return;
      setState(() {
        _rows = results[0] as List<BranchStockRow>;
        _canReceive = results[1] as bool;
        _access = results[2] as OwnAccess;
        _canAddCatalog = results[3] as bool;
        _catalogAccess = results[4] as OwnAccess;
        _branchTypes = results[5] as List<BusinessTypeOption>;
        _catalog = results[6] as List<CatalogItemEntry>;
        _loading = false;
        _error = null;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _onCatalogSearch(String q) async {
    setState(() => _catalogQuery = q);
    try {
      final items = await _repo.fetchCatalogList(query: q);
      if (!mounted) return;
      setState(() => _catalog = items);
    } catch (_) {}
  }

  List<BranchStockRow> get _visible {
    return _rows.where((r) {
      switch (_chip) {
        case 'low':
          if (!r.low) return false;
        case 'expiring':
          if (!r.expiring) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _requestAccess() async {
    final reason = await _showStockSheet<String>(
      context,
      builder: (_) => _ReasonSheet(),
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _repo.requestAccess(reason);
      await _load(silent: true);
      if (mounted) empToast(context, 'Request sent. The admin will decide.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _endAccess() async {
    final id = _access.requestId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: Text('End your stock access?', style: empSans(16, weight: FontWeight.w700, color: empInk)),
        content: Text('You will no longer be able to receive stock until granted again.', style: empSans(13, color: empMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep it', style: empSans(13, color: empMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: empPrimaryButton(height: 36),
            child: const Text('I’m done'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.endOwnAccess(id);
      await _load(silent: true);
      if (mounted) empToast(context, 'Access ended.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _requestCatalogAccess() async {
    final reason = await _showStockSheet<String>(
      context,
      builder: (_) => _ReasonSheet(
        title: 'Request catalog access',
        subtitle: 'Specify why adding new products is needed.',
        hint: 'e.g. New cosmetics line arrived, not in catalog yet',
      ),
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _repo.requestCatalogAccess(reason);
      await _load(silent: true);
      if (mounted) empToast(context, 'Request sent. The admin will decide.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _endCatalogAccess() async {
    final id = _catalogAccess.requestId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        title: Text('End your catalog access?', style: empSans(16, weight: FontWeight.w700, color: empInk)),
        content: Text('You will no longer be able to add new products until granted again.', style: empSans(13, color: empMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep it', style: empSans(13, color: empMuted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: empPrimaryButton(height: 36),
            child: const Text('I’m done'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.endOwnCatalogAccess(id);
      await _load(silent: true);
      if (mounted) empToast(context, 'Catalog access ended.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _addCatalogItem() async {
    final bid = _branchId;
    if (bid == null) return;
    final added = await _showStockSheet<String>(
      context,
      builder: (_) => _AddCatalogItemSheet(repo: _repo, branchTypes: _branchTypes),
    );
    if (added != null && mounted) {
      await _load(silent: true);
      if (mounted) empToast(context, added);
    }
  }

  Future<void> _receive() async {
    final bid = _branchId;
    if (bid == null) return;
    final done = await _showStockSheet<bool>(
      context,
      builder: (_) => _ReceiveSheet(repo: _repo, branchId: bid),
    );
    if (done == true && mounted) {
      await _load(silent: true);
      if (mounted) empToast(context, 'Stock received and available for sale.');
    }
  }

  // ---- Build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final wideScreen =
        MediaQuery.of(context).size.width >= empWideBreakpoint;
    return Scaffold(
      backgroundColor: empBg,
      floatingActionButton: _buildBackToTopButton(wideScreen),
      body: SafeArea(
        child: RefreshIndicator(
          color: empPrimary,
          onRefresh: () => _load(silent: true),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= empWideBreakpoint;
              return SingleChildScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 18,
                  wide ? 28 : 14,
                  wide ? 32 : 18,
                  32,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: _body(wide),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildBackToTopButton(bool wide) {
    return AnimatedOpacity(
      opacity: _showBackToTop ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: AnimatedScale(
        scale: _showBackToTop ? 1.0 : 0.8,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_showBackToTop,
          child: wide
              ? FloatingActionButton.extended(
                  heroTag: 'emp_stock_back_to_top',
                  onPressed: _scrollToTop,
                  backgroundColor: Colors.white,
                  foregroundColor: empPrimary,
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: const BorderSide(color: empBorder),
                  ),
                  icon: const Icon(Icons.arrow_upward,
                      size: 16, color: empPrimary),
                  label: Text(
                    'Back to top',
                    style:
                        empSans(12.5, weight: FontWeight.w600, color: empInk),
                  ),
                )
              : FloatingActionButton.small(
                  heroTag: 'emp_stock_back_to_top',
                  onPressed: _scrollToTop,
                  backgroundColor: Colors.white,
                  foregroundColor: empPrimary,
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: const BorderSide(color: empBorder),
                  ),
                  tooltip: 'Back to top',
                  child: const Icon(Icons.arrow_upward,
                      size: 18, color: empPrimary),
                ),
        ),
      ),
    );
  }

  Widget _body(bool wide) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (_error != null || _branchId == null) {
      return EmpEmpty(
        icon: Icons.error_outline,
        title: 'Couldn’t load stock',
        message: _error ?? 'No branch assigned.',
        action: OutlinedButton(
          onPressed: _load,
          style: empOutlineButton(height: 36),
          child: const Text('Retry'),
        ),
      );
    }

    final lowCount = _rows.where((r) => r.low).length;
    final expCount = _rows.where((r) => r.expiring).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Branch Stock', style: empSans(22, weight: FontWeight.w700, color: empInk)),
                  const SizedBox(height: 3),
                  Text(
                    '${widget.branchName} · ${_rows.length} ${_rows.length == 1 ? 'item' : 'items'} in inventory',
                    style: empSans(12.5, color: empMuted),
                  ),
                ],
              ),
            ),
            if (_canReceive)
              FilledButton.icon(
                onPressed: _receive,
                style: empPrimaryButton(height: 38),
                icon: const Icon(Icons.add_box_outlined, size: 17),
                label: const Text('Receive stock'),
              )
            else if (_access.state != OwnAccessState.pending)
              OutlinedButton.icon(
                onPressed: _requestAccess,
                style: empOutlineButton(height: 38),
                icon: const Icon(Icons.lock_open_outlined, size: 16),
                label: const Text('Request receive access'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                _branchTypes.isEmpty
                    ? 'Catalog: this branch has no business type set — ask the admin.'
                    : 'Catalog: ${_branchTypes.map((t) => t.name).join(' · ')}',
                style: empSans(12, color: empMuted),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => setState(
                  () => _chip = _chip == 'catalog' ? 'all' : 'catalog'),
              style: empOutlineButton(height: 38),
              icon: Icon(
                _chip == 'catalog'
                    ? Icons.inventory_2_outlined
                    : Icons.menu_book_outlined,
                size: 16,
              ),
              label: Text(_chip == 'catalog' ? 'View stock' : 'View catalog'),
            ),
            if (_canAddCatalog) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _addCatalogItem,
                style: empOutlineButton(height: 38),
                icon: const Icon(Icons.playlist_add_outlined, size: 16),
                label: const Text('Add product'),
              ),
            ] else if (_catalogAccess.state != OwnAccessState.pending) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _requestCatalogAccess,
                style: empOutlineButton(height: 38),
                icon: const Icon(Icons.library_add_outlined, size: 16),
                label: const Text('Request catalog access'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        _accessBanner(),
        _catalogBanner(),
        const SizedBox(height: 16),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              EmpFilterPill(
                label: 'All (${_rows.length})',
                selected: _chip == 'all',
                onTap: () => setState(() => _chip = 'all'),
              ),
              const SizedBox(width: 8),
              EmpFilterPill(
                label: 'Low stock ($lowCount)',
                selected: _chip == 'low',
                onTap: () => setState(() => _chip = 'low'),
              ),
              const SizedBox(width: 8),
              EmpFilterPill(
                label: 'Expiring ($expCount)',
                selected: _chip == 'expiring',
                onTap: () => setState(() => _chip = 'expiring'),
              ),
              const SizedBox(width: 8),
              EmpFilterPill(
                label: 'Catalog (${_catalog.length})',
                selected: _chip == 'catalog',
                onTap: () => setState(() => _chip = 'catalog'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_chip == 'catalog') ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Catalog products (${_catalog.length})',
                  style: empSans(13.5, weight: FontWeight.w700, color: empInk),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _showCatalogSearch = !_showCatalogSearch;
                    if (!_showCatalogSearch) {
                      _catalogSearchCtrl.clear();
                      _onCatalogSearch('');
                    }
                  });
                },
                style: empOutlineButton(height: 36),
                icon: Icon(
                  _showCatalogSearch ? Icons.close : Icons.search,
                  size: 16,
                ),
                label: Text(
                  _showCatalogSearch ? 'Close search' : 'Search catalog',
                ),
              ),
            ],
          ),
          if (_showCatalogSearch || _catalogSearchCtrl.text.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: EmpSearchField(
                    controller: _catalogSearchCtrl,
                    hint: 'Search catalog by product name…',
                    onChanged: _onCatalogSearch,
                  ),
                ),
                if (_catalogQuery.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear, size: 18, color: empMuted),
                    onPressed: () {
                      _catalogSearchCtrl.clear();
                      _onCatalogSearch('');
                    },
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 14),
          _catalogList(wide),
        ] else ...[
          EmpSearchField(
            controller: _searchCtrl,
            hint: 'Search stock by product or item name…',
            onChanged: (v) {
              setState(() => _query = v);
              _load(silent: true);
            },
          ),
          const SizedBox(height: 16),
          _list(wide),
        ],
      ],
    );
  }

  Widget _accessBanner() {
    if (_canReceive && _access.state == OwnAccessState.active) {
      final until = _access.expiresAt == null
          ? 'until removed by admin'
          : 'until ${_fmtTime(_access.expiresAt!)}';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: empBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            EmpStatusPill.active('Active permission'),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'You can receive deliveries ($until).',
                style: empSans(12.5, color: empMuted),
              ),
            ),
            TextButton(
              onPressed: _endAccess,
              style: TextButton.styleFrom(
                foregroundColor: empInk,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text('Done receiving', style: empSans(12, weight: FontWeight.w600, color: empPrimary)),
            ),
          ],
        ),
      );
    }
    if (_access.state == OwnAccessState.pending) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: empBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            EmpStatusPill.warning('Pending review'),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Access request sent. Waiting for admin approval.',
                style: empSans(12.5, color: empMuted),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _catalogBanner() {
    if (_canAddCatalog && _catalogAccess.state == OwnAccessState.active) {
      final until = _catalogAccess.expiresAt == null
          ? 'until removed by admin'
          : 'until ${_fmtTime(_catalogAccess.expiresAt!)}';
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: empBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            EmpStatusPill.active('Can add products'),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'New products you add join the shared catalog ($until).',
                style: empSans(12.5, color: empMuted),
              ),
            ),
            TextButton(
              onPressed: _endCatalogAccess,
              style: TextButton.styleFrom(
                foregroundColor: empInk,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text('Done adding', style: empSans(12, weight: FontWeight.w600, color: empPrimary)),
            ),
          ],
        ),
      );
    }
    if (_catalogAccess.state == OwnAccessState.pending) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: empBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            EmpStatusPill.warning('Catalog pending'),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Catalog request sent. Waiting for admin approval.',
                style: empSans(12.5, color: empMuted),
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _list(bool wide) {
    final rows = _visible;
    if (rows.isEmpty) {
      return EmpEmpty(
        icon: Icons.inventory_2_outlined,
        title: 'No stock found',
        message: _query.trim().isEmpty
            ? 'No items match the selected filter.'
            : 'No stock found for “${_query.trim()}”.',
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: empBorder),
        itemBuilder: (_, i) {
          final r = rows[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.name,
                        style: empSans(13.5, weight: FontWeight.w600, color: empInk),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (r.low) ...[
                            EmpStatusPill.warning('Low stock'),
                            const SizedBox(width: 6),
                          ],
                          if (r.expiring) ...[
                            EmpStatusPill.danger('Expiring'),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            'Retail: ${empMk(r.retail)}',
                            style: empSans(12, color: empMuted),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${empQty(r.qty)} ${r.unit}',
                      style: empMono(
                        14,
                        weight: FontWeight.w700,
                        color: r.low ? empWarn : empInk,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'on hand',
                      style: empSans(10.5, color: empMuted),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _catalogList(bool wide) {
    if (_catalog.isEmpty) {
      return EmpEmpty(
        icon: Icons.category_outlined,
        title: 'No catalog items found',
        message: _catalogQuery.trim().isEmpty
            ? 'No items found in the shared catalog.'
            : 'No catalog items match “${_catalogQuery.trim()}”.',
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: _catalog.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: empBorder),
        itemBuilder: (_, i) {
          final c = _catalog[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.name,
                        style: empSans(13.5,
                            weight: FontWeight.w600, color: empInk),
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: empSurface,
                              border: Border.all(color: empBorder),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              c.category,
                              style: empSans(11, color: empMuted),
                            ),
                          ),
                          Text(
                            'Unit: ${c.unit}',
                            style: empSans(11.5, color: empMuted),
                          ),
                          Text(
                            '· ${c.businessTypeName}',
                            style: empSans(11.5, color: empMuted),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Reorder: ${c.reorderLevel.toStringAsFixed(c.reorderLevel % 1 == 0 ? 0 : 1)}',
                      style: empMono(12,
                          weight: FontWeight.w600, color: empInk),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'min level',
                      style: empSans(10.5, color: empMuted),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _fmtTime(DateTime dt) {
    final l = dt.toLocal();
    return '${l.day}/${l.month}/${l.year} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

Future<T?> _showStockSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final wide = MediaQuery.of(context).size.width >= empWideBreakpoint;
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(child: builder(ctx)),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: builder,
  );
}

class _ReasonSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final String hint;
  const _ReasonSheet({
    this.title = 'Request stock access',
    this.subtitle = 'Specify why delivery access is needed.',
    this.hint = 'e.g. Supplier delivery arrived at branch',
  });
  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: widget.title,
      subtitle: widget.subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            minLines: 2,
            maxLines: 3,
            style: empSans(14, color: empInk),
            decoration: empField('Reason', hint: widget.hint),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
            style: empPrimaryButton(),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// RECEIVE SHEET — delivery lines then one atomic receive_stock_delivery().
// ============================================================================

class _ReceiveLineForm {
  CatalogOption? item;
  final qtyCtrl = TextEditingController();
  final batchCtrl = TextEditingController();
  final buyCtrl = TextEditingController();
  final retailCtrl = TextEditingController();
  final wholeCtrl = TextEditingController();
  DateTime? expiry;
  void dispose() {
    qtyCtrl.dispose();
    batchCtrl.dispose();
    buyCtrl.dispose();
    retailCtrl.dispose();
    wholeCtrl.dispose();
  }
}

class _ReceiveSheet extends StatefulWidget {
  final CashierStockRepository repo;
  final String branchId;
  const _ReceiveSheet({required this.repo, required this.branchId});

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  final List<_ReceiveLineForm> _lines = [_ReceiveLineForm()];
  List<SupplierOption> _suppliers = [];
  String? _supplierId;
  final _invoiceCtrl = TextEditingController();
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _invoiceCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuppliers() async {
    try {
      final s = await widget.repo.fetchSuppliers();
      if (mounted) setState(() => _suppliers = s);
    } catch (_) {}
  }

  Future<void> _pickItem(_ReceiveLineForm line) async {
    final picked = await _showStockSheet<CatalogOption>(
      context,
      builder: (_) => _ItemPickerSheet(repo: widget.repo),
    );
    if (picked != null && mounted) setState(() => line.item = picked);
  }

  Future<void> _submit() async {
    final parsed = <ReceiveLine>[];
    for (final l in _lines) {
      if (l.item == null) {
        setState(() => _formError = 'Pick an item for every line.');
        return;
      }
      final qty = double.tryParse(l.qtyCtrl.text.trim());
      final buy = double.tryParse(l.buyCtrl.text.trim());
      final retail = double.tryParse(l.retailCtrl.text.trim());
      final whole = l.wholeCtrl.text.trim().isEmpty ? null : double.tryParse(l.wholeCtrl.text.trim());
      if (qty == null || qty <= 0 || buy == null || buy < 0 || retail == null || retail < 0) {
        setState(() => _formError = 'Each line needs quantity, buying and retail prices.');
        return;
      }
      if (whole != null && whole < 0) {
        setState(() => _formError = 'Wholesale prices cannot be negative.');
        return;
      }
      String? exp;
      if (l.expiry != null) {
        exp = '${l.expiry!.year}-${l.expiry!.month.toString().padLeft(2, '0')}-${l.expiry!.day.toString().padLeft(2, '0')}';
      }
      parsed.add(ReceiveLine(
        itemId: l.item!.id,
        quantity: qty,
        buyingPrice: buy,
        retailPrice: retail,
        wholesalePrice: whole,
        expiryDate: exp,
        batchNumber: l.batchCtrl.text,
      ));
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.receive(
        branchId: widget.branchId,
        supplierId: _supplierId,
        invoice: _invoiceCtrl.text,
        lines: parsed,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on StockException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Receive stock',
      subtitle: 'Delivered items are recorded straight into branch inventory.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
              color: Colors.white,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: _supplierId,
                isExpanded: true,
                hint: Text('Supplier (optional)', style: empSans(13.5, color: empMuted)),
                style: empSans(14, color: empInk),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No supplier')),
                  for (final s in _suppliers) DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _supplierId = v),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _invoiceCtrl,
            style: empSans(14, color: empInk),
            decoration: empField('Invoice number (optional)'),
          ),
          const SizedBox(height: 14),
          for (int i = 0; i < _lines.length; i++) ...[
            _lineCard(i, _lines[i]),
            const SizedBox(height: 10),
          ],
          OutlinedButton.icon(
            onPressed: () => setState(() => _lines.add(_ReceiveLineForm())),
            style: empOutlineButton(height: 40),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add another item'),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(_formError!, style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: empPrimaryButton(),
            child: _saving
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Save delivery'),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(int i, _ReceiveLineForm l) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Item ${i + 1}',
                  style: empSans(12.5, weight: FontWeight.w600, color: empMuted)),
              const Spacer(),
              if (_lines.length > 1)
                IconButton(
                  icon: const Icon(Icons.close, size: 17, color: empMuted),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() {
                    l.dispose();
                    _lines.removeAt(i);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (l.item == null)
            InkWell(
              onTap: () => _pickItem(l),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  border: Border.all(color: empBorder),
                  borderRadius: BorderRadius.circular(4),
                  color: empBg,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 18, color: empMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Search item from catalog…',
                        style: empSans(13.5, color: empMuted),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, color: empMuted),
                  ],
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: empBorder),
                borderRadius: BorderRadius.circular(4),
                color: empBg,
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, size: 18, color: empPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.item!.name,
                          style: empSans(13.5, weight: FontWeight.w700, color: empInk),
                        ),
                        if (l.item!.category.isNotEmpty || l.item!.unit.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${l.item!.category.isNotEmpty ? l.item!.category : 'Uncategorised'}${l.item!.unit.isNotEmpty ? ' · Unit: ${l.item!.unit}' : ''}',
                            style: empSans(11.5, color: empMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _pickItem(l),
                    icon: const Icon(Icons.search, size: 15),
                    label: const Text('Change'),
                    style: TextButton.styleFrom(
                      foregroundColor: empPrimary,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: l.qtyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Qty'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.batchCtrl,
                  style: empSans(14, color: empInk),
                  decoration: empField('Batch no.'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: l.buyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Buying'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.retailCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Retail'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.wholeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Wholesale'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final today = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: today.add(const Duration(days: 365)),
                firstDate: today,
                lastDate: DateTime(today.year + 10),
              );
              if (picked != null) setState(() => l.expiry = picked);
            },
            style: empOutlineButton(height: 38),
            icon: const Icon(Icons.event_outlined, size: 15, color: empMuted),
            label: Text(
              l.expiry == null ? 'Set expiry date' : 'Expires: ${l.expiry!.day}/${l.expiry!.month}/${l.expiry!.year}',
              style: empSans(12.5, color: empInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemPickerSheet extends StatefulWidget {
  final CashierStockRepository repo;
  const _ItemPickerSheet({required this.repo});

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  final _searchCtrl = TextEditingController();
  List<CatalogOption> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() => _loading = true);
    try {
      final res = await widget.repo.searchCatalog(q);
      if (!mounted) return;
      if (_searchCtrl.text != q && q.isNotEmpty) return;
      setState(() {
        _results = res;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Pick catalog item',
      subtitle: 'Search products by name or select from the catalog below.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EmpSearchField(
            controller: _searchCtrl,
            hint: 'Search item name…',
            onChanged: _search,
          ),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: empPrimary),
                ),
              ),
            )
          else if (_results.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _results.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: empBorder),
                itemBuilder: (_, i) {
                  final c = _results[i];
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c.name, style: empSans(13.5, weight: FontWeight.w600, color: empInk)),
                                if (c.category.isNotEmpty || c.unit.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    '${c.category.isNotEmpty ? c.category : 'Uncategorised'}${c.unit.isNotEmpty ? ' · Unit: ${c.unit}' : ''}',
                                    style: empSans(11.5, color: empMuted),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, size: 17, color: empMuted),
                        ],
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  _searchCtrl.text.trim().isEmpty
                      ? 'No items found in catalog.'
                      : 'No items match “${_searchCtrl.text.trim()}”.',
                  textAlign: TextAlign.center,
                  style: empSans(12.5, color: empMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// ADD CATALOG ITEM — employee creates a product in the shared catalog.
//   Business type is limited to what this branch runs; the new product is
//   then visible to every branch running that type. Writes go through
//   add_catalog_item(), which enforces catalog access + branch type.
// ============================================================================

class _AddCatalogItemSheet extends StatefulWidget {
  final CashierStockRepository repo;
  final List<BusinessTypeOption> branchTypes;
  const _AddCatalogItemSheet({required this.repo, required this.branchTypes});

  @override
  State<_AddCatalogItemSheet> createState() => _AddCatalogItemSheetState();
}

class _AddCatalogItemSheetState extends State<_AddCatalogItemSheet> {
  final _nameCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: 'unit');
  final _reorderCtrl = TextEditingController(text: '10');
  bool _rx = false;
  String? _typeId;
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    if (widget.branchTypes.isNotEmpty) _typeId = widget.branchTypes.first.id;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _categoryCtrl.dispose();
    _unitCtrl.dispose();
    _reorderCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _formError = 'Product name is required.');
      return;
    }
    if (_typeId == null || _typeId!.isEmpty) {
      setState(() => _formError = 'Pick the business type for this product.');
      return;
    }
    final reorder = double.tryParse(_reorderCtrl.text.trim());
    if (reorder == null || reorder < 0) {
      setState(() => _formError = 'Reorder level must be zero or above.');
      return;
    }
    // Duplicate guard: same name (case-insensitive) already catalogued.
    // Same unit means it is the same item — blocked, no override.
    // Different unit may legitimately be a separate product (bottle vs
    // tablets), so that case only warns and lets the user confirm.
    // Advisory only: a failed lookup must not block the save.
    try {
      final matches = await widget.repo.findItemsByName(_nameCtrl.text);
      if (matches.isNotEmpty && mounted) {
        final enteredUnit = _unitCtrl.text.trim().isEmpty
            ? 'unit'
            : _unitCtrl.text.trim();
        final sameUnit = matches
            .where(
              (m) =>
                  m.unit.trim().toLowerCase() == enteredUnit.toLowerCase(),
            )
            .toList();
        if (sameUnit.isNotEmpty) {
          final listed = sameUnit
              .take(3)
              .map((m) =>
                  '• ${m.name} (${m.unit}${m.businessType.isNotEmpty ? ' · ${m.businessType}' : ''})')
              .join('\n');
          setState(() => _formError =
              '“${_nameCtrl.text.trim()}” is already in the catalog with the same unit ($enteredUnit):\n$listed\nThat is the same item — pick it from the catalog instead of adding it again.');
          return;
        }
        final listed = matches
            .take(5)
            .map((m) =>
                '• ${m.name} (${m.unit}${m.businessType.isNotEmpty ? ' · ${m.businessType}' : ''})')
            .join('\n');
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            title: Text(
              'Same name, different unit',
              style: empSans(16, weight: FontWeight.w700, color: empInk),
            ),
            content: Text(
              '“${_nameCtrl.text.trim()}” is already in the catalog with a different unit:\n$listed\n\nYou entered unit “$enteredUnit”. The same product sold in a different unit counts as a separate product — continue only if that is what you mean.',
              style: empSans(13, color: empMuted),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('Keep editing', style: empSans(13, color: empMuted)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: empPrimaryButton(height: 36),
                child: const Text('Add anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
    } catch (_) {
      // Fall through to the save below.
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      final typeName = widget.branchTypes
          .where((t) => t.id == _typeId)
          .map((t) => t.name)
          .join();
      await widget.repo.addCatalogItem(
        name: _nameCtrl.text,
        businessTypeId: _typeId!,
        category: _categoryCtrl.text,
        unit: _unitCtrl.text,
        reorderLevel: reorder,
        requiresPrescription: _rx,
      );
      if (mounted) {
        Navigator.of(context).pop(
          '“${_nameCtrl.text.trim()}” added to the $typeName catalog — visible to all $typeName branches.',
        );
      }
    } on StockException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Add product to catalog',
      subtitle: 'Only for business types your branch runs. Shared with all branches of that type.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: empSans(14, color: empInk),
            decoration: empField('Product name', hint: 'e.g. Amoxicillin 250mg, Lipstick Red'),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
              color: Colors.white,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _typeId,
                isExpanded: true,
                hint: Text('Business type', style: empSans(13.5, color: empMuted)),
                style: empSans(14, color: empInk),
                items: [
                  for (final t in widget.branchTypes)
                    DropdownMenuItem(value: t.id, child: Text(t.name)),
                ],
                onChanged: (v) => setState(() => _typeId = v),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _categoryCtrl,
                  textCapitalization: TextCapitalization.words,
                  style: empSans(14, color: empInk),
                  decoration: empField('Category (optional)'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _unitCtrl,
                  style: empSans(14, color: empInk),
                  decoration: empField('Unit', hint: 'tablet, bottle…'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reorderCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: empSans(14, color: empInk),
            decoration: empField('Reorder level'),
          ),
          CheckboxListTile(
            value: _rx,
            onChanged: (v) => setState(() => _rx = v ?? false),
            title: Text('Requires prescription', style: empSans(13.5, color: empInk)),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          if (_formError != null) ...[
            const SizedBox(height: 6),
            Text(_formError!, style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: empPrimaryButton(),
            child: _saving
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Add to catalog'),
          ),
        ],
      ),
    );
  }
}
