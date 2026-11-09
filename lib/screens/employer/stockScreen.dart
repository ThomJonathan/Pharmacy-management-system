import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../core/quantityUnit.dart';
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

  bool _showBackToTop = false;
  int _tab = 0; // 0 = Branch Stock, 1 = Catalog

  bool _loading = true;
  String? _error;
  List<BranchStockRow> _rows = [];
  String _query = '';
  String _chip = 'all'; // all | low | expiring

  List<EmployeeCatalogItem> _catalog = [];
  String? _catalogError;
  String _catalogSearch = '';
  String? _catalogCategory;
  static const int _catalogPageSize = 80;
  int _catalogVisibleLimit = _catalogPageSize;

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
    final show = _scrollController.hasClients && _scrollController.offset > 250;
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
      ]);
      // Catalog is loaded separately: a catalog-only permission/schema problem
      // must never blank out the branch stock tab.
      var catalog = _catalog;
      String? catalogError;
      try {
        catalog = await _repo
            .fetchCatalog()
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        catalogError = e.toString();
      }
      if (!mounted) return;
      setState(() {
        _rows = results[0] as List<BranchStockRow>;
        _canReceive = results[1] as bool;
        _access = results[2] as OwnAccess;
        _canAddCatalog = results[3] as bool;
        _catalogAccess = results[4] as OwnAccess;
        _branchTypes = results[5] as List<BusinessTypeOption>;
        _catalog = catalog;
        _catalogError = catalogError;
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

  List<EmployeeCatalogItem> get _visibleCatalog {
    final q = _catalogSearch.trim().toLowerCase();
    return _catalog.where((c) {
      if (_catalogCategory != null && c.category != _catalogCategory) {
        return false;
      }
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.category.toLowerCase().contains(q) ||
          c.businessTypeName.toLowerCase().contains(q);
    }).toList();
  }

  void _updateCatalogSearch(String value) {
    setState(() {
      _catalogSearch = value;
      _catalogVisibleLimit = _catalogPageSize;
    });
  }

  void _updateCatalogCategory(String? value) {
    setState(() {
      _catalogCategory = value;
      _catalogVisibleLimit = _catalogPageSize;
    });
  }

  void _clearCatalogFilters() {
    _catalogSearchCtrl.clear();
    setState(() {
      _catalogSearch = '';
      _catalogCategory = null;
      _catalogVisibleLimit = _catalogPageSize;
    });
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
    return Scaffold(
      backgroundColor: empBg,
      floatingActionButton: _showBackToTop
          ? FloatingActionButton.extended(
              onPressed: _scrollToTop,
              backgroundColor: empPrimary,
              foregroundColor: Colors.white,
              elevation: 4,
              icon: const Icon(Icons.arrow_upward_rounded, size: 18),
              label: const Text(
                'Back to top',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            )
          : null,
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
                  _showBackToTop ? 96 : 32,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabSwitcher(wide),
        const SizedBox(height: 16),
        if (_tab == 0) _stockView(wide) else _catalogView(wide),
      ],
    );
  }

  Widget _tabSwitcher(bool wide) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _tab = 0),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _tab == 0 ? empPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inventory_2_outlined,
                      size: 16,
                      color: _tab == 0 ? Colors.white : empMuted,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        wide
                            ? 'Branch Stock (${_rows.length})'
                            : 'Stock (${_rows.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: empSans(
                          13,
                          weight: FontWeight.w600,
                          color: _tab == 0 ? Colors.white : empMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _tab = 1),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _tab == 1 ? empPrimary : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.category_outlined,
                      size: 16,
                      color: _tab == 1 ? Colors.white : empMuted,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Catalog (${_catalog.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: empSans(
                          13,
                          weight: FontWeight.w600,
                          color: _tab == 1 ? Colors.white : empMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Page heading that keeps its action beside the title on desktop and
  /// moves it below the title on phones, so long button labels never squeeze
  /// the heading or overflow.
  Widget _pageHeading({
    required String title,
    required String subtitle,
    required bool wide,
    Widget? action,
  }) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: empSans(22, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: empSans(12.5, color: empMuted)),
      ],
    );
    if (action == null) return heading;
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: heading),
          const SizedBox(width: 12),
          action,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading,
        const SizedBox(height: 10),
        Align(alignment: Alignment.centerLeft, child: action),
      ],
    );
  }

  Widget _stockView(bool wide) {
    final lowCount = _rows.where((r) => r.low).length;
    final expCount = _rows.where((r) => r.expiring).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pageHeading(
          title: 'Branch Stock',
          subtitle:
              '${widget.branchName} · ${_rows.length} ${_rows.length == 1 ? 'item' : 'items'} in inventory',
          wide: wide,
          action: _canReceive
              ? FilledButton.icon(
                  onPressed: _receive,
                  style: empPrimaryButton(height: 38),
                  icon: const Icon(Icons.add_box_outlined, size: 17),
                  label: const Text('Receive stock'),
                )
              : _access.state != OwnAccessState.pending
                  ? OutlinedButton.icon(
                      onPressed: _requestAccess,
                      style: empOutlineButton(height: 38),
                      icon: const Icon(Icons.lock_open_outlined, size: 16),
                      label: const Text('Request receive access'),
                    )
                  : null,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _branchTypes.isEmpty
                  ? 'Catalog: this branch has no business type set — ask the admin.'
                  : 'Catalog: ${_branchTypes.map((t) => t.name).join(' · ')}',
              style: empSans(12, color: empMuted),
            ),
            if (_canAddCatalog)
              OutlinedButton.icon(
                onPressed: _addCatalogItem,
                style: empOutlineButton(height: 38),
                icon: const Icon(Icons.playlist_add_outlined, size: 16),
                label: const Text('Add product'),
              )
            else if (_catalogAccess.state != OwnAccessState.pending)
              OutlinedButton.icon(
                onPressed: _requestCatalogAccess,
                style: empOutlineButton(height: 38),
                icon: const Icon(Icons.library_add_outlined, size: 16),
                label: const Text('Request catalog access'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _accessBanner(),
        _catalogBanner(),
        const SizedBox(height: 16),
        TextField(
          controller: _searchCtrl,
          onChanged: (v) {
            setState(() => _query = v);
            _load(silent: true);
          },
          style: empSans(14, color: empInk),
          decoration: empField('Search stock by product or item name…').copyWith(
            prefixIcon: const Icon(Icons.search, size: 18, color: empMuted),
            suffixIcon: _query.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18, color: empMuted),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                      _load(silent: true);
                    },
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
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
            ],
          ),
        ),
        const SizedBox(height: 16),
        _list(wide),
      ],
    );
  }

  Widget _catalogView(bool wide) {
    final catalogAll = _visibleCatalog;
    final catalogList = catalogAll.take(_catalogVisibleLimit).toList();
    final categories = <String>{
      for (final it in _catalog)
        if (it.category.isNotEmpty) it.category,
    }.toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pageHeading(
          title: 'Catalog Products',
          subtitle: (_catalogSearch.trim().isNotEmpty ||
                  _catalogCategory != null)
              ? '${catalogAll.length} of ${_catalog.length} products match'
              : '${_catalog.length} ${_catalog.length == 1 ? 'product' : 'products'} available in system',
          wide: wide,
          action: _canAddCatalog
              ? FilledButton.icon(
                  onPressed: _addCatalogItem,
                  style: empPrimaryButton(height: 38),
                  icon: const Icon(Icons.playlist_add_outlined, size: 17),
                  label: const Text('Add product'),
                )
              : _catalogAccess.state != OwnAccessState.pending
                  ? OutlinedButton.icon(
                      onPressed: _requestCatalogAccess,
                      style: empOutlineButton(height: 38),
                      icon: const Icon(Icons.library_add_outlined, size: 16),
                      label: const Text('Request access to add'),
                    )
                  : null,
        ),
        const SizedBox(height: 16),
        _catalogBanner(),
        if (_catalogError != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: empDanger),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 18, color: empDanger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Could not load the catalog. ${_catalogError!}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: empSans(12, color: empMuted),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _load(silent: true),
                  style: TextButton.styleFrom(foregroundColor: empPrimary),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: empBorder),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, box) {
                  final compact = box.maxWidth < 520;
                  final searchField = TextField(
                    controller: _catalogSearchCtrl,
                    onChanged: _updateCatalogSearch,
                    onSubmitted: _updateCatalogSearch,
                    textInputAction: TextInputAction.search,
                    style: empSans(14, color: empInk),
                    decoration:
                        empField('Search catalog items by name or category…')
                            .copyWith(
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 18,
                        color: empMuted,
                      ),
                      suffixIcon: _catalogSearch.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear,
                                size: 18,
                                color: empMuted,
                              ),
                              tooltip: 'Clear search',
                              onPressed: () {
                                _catalogSearchCtrl.clear();
                                _updateCatalogSearch('');
                              },
                            )
                          : null,
                    ),
                  );
                  final searchButton = FilledButton.icon(
                    onPressed: () {
                      _updateCatalogSearch(
                        _catalogSearchCtrl.text.trim(),
                      );
                    },
                    style: empPrimaryButton(height: 42),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Search'),
                  );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        searchField,
                        const SizedBox(height: 8),
                        SizedBox(width: double.infinity, child: searchButton),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: searchField),
                      const SizedBox(width: 8),
                      searchButton,
                    ],
                  );
                },
              ),
              if (categories.isNotEmpty) ...[
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      EmpFilterPill(
                        label: 'All (${_catalog.length})',
                        selected: _catalogCategory == null,
                        onTap: () => _updateCatalogCategory(null),
                      ),
                      for (final cat in categories) ...[
                        const SizedBox(width: 8),
                        EmpFilterPill(
                          label: cat,
                          selected: _catalogCategory == cat,
                          onTap: () => _updateCatalogCategory(
                            (_catalogCategory == cat) ? null : cat,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (catalogList.isEmpty)
          EmpEmpty(
            icon: Icons.category_outlined,
            title: 'No products found',
            message: _catalogSearch.trim().isNotEmpty
                ? 'No catalog items match “${_catalogSearch.trim()}”${_catalogCategory != null ? ' in $_catalogCategory' : ''}.'
                : _catalogCategory != null
                    ? 'No products in $_catalogCategory.'
                    : 'No catalog products available.',
            action: (_catalogSearch.trim().isNotEmpty ||
                    _catalogCategory != null)
                ? OutlinedButton(
                    onPressed: _clearCatalogFilters,
                    style: empOutlineButton(height: 36),
                    child: const Text('Clear filters'),
                  )
                : null,
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: List.generate(catalogList.length, (i) {
                final it = catalogList[i];
                final isLast = i == catalogList.length - 1;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: isLast ? null : const Border(bottom: BorderSide(color: empBorder)),
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
                                    it.name,
                                    style: empSans(13.5, weight: FontWeight.w600, color: empInk),
                                  ),
                                ),
                                if (it.requiresPrescription) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: empPrimary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      'Rx',
                                      style: empSans(10.5, weight: FontWeight.w700, color: empPrimary),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${it.businessTypeName} · ${it.category} · Base unit: ${it.unit}${it.quantityStep != 1 ? ' · step ${fmtQty(it.quantityStep)}' : ''}${it.units.isNotEmpty ? ' · extra: ${it.units.map((u) => '${u.name} (${fmtQty(u.factor)})').join(', ')}' : ''}',
                              style: empSans(11.5, color: empMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'Reorder at',
                            style: empSans(10.5, color: empMuted),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${empQty(it.reorderLevel)} ${it.unit}',
                            style: empMono(12.5, weight: FontWeight.w600, color: empInk),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
        if (catalogAll.length > catalogList.length) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => setState(
              () => _catalogVisibleLimit += _catalogPageSize,
            ),
            style: empOutlineButton(height: 40),
            child: Text(
              'Show more (${catalogAll.length - catalogList.length} remaining)',
            ),
          ),
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
      child: Column(
        children: List.generate(rows.length, (i) {
          final r = rows[i];
          final isLast = i == rows.length - 1;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: isLast ? null : const Border(bottom: BorderSide(color: empBorder)),
            ),
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
        }),
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
              Expanded(
                child: Text(l.item?.name ?? 'Item ${i + 1}',
                    style: empSans(14, weight: FontWeight.w700, color: empInk)),
              ),
              TextButton(
                onPressed: () => _pickItem(l),
                style: TextButton.styleFrom(
                  foregroundColor: empPrimary,
                  minimumSize: const Size(0, 32),
                ),
                child: Text(l.item == null ? 'Pick item' : 'Change',
                    style: empSans(12.5, weight: FontWeight.w600, color: empPrimary)),
              ),
              if (_lines.length > 1)
                IconButton(
                  icon: const Icon(Icons.close, size: 17, color: empMuted),
                  onPressed: () => setState(() {
                    l.dispose();
                    _lines.removeAt(i);
                  }),
                ),
            ],
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
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await widget.repo.searchCatalog(q);
      if (!mounted) return;
      if (_searchCtrl.text != q) return;
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
      subtitle: 'Type item name to search catalog.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: _search,
            style: empSans(14, color: empInk),
            decoration: empField('Type a product name…').copyWith(
              prefixIcon: const Icon(Icons.search, size: 18, color: empMuted),
            ),
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
            for (final c in _results)
              InkWell(
                onTap: () => Navigator.of(context).pop(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(c.name, style: empSans(13.5, weight: FontWeight.w600, color: empInk)),
                      ),
                      const Icon(Icons.chevron_right, size: 17, color: empMuted),
                    ],
                  ),
                ),
              )
          else if (_searchCtrl.text.trim().length >= 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No items match “${_searchCtrl.text.trim()}”.',
                  textAlign: TextAlign.center, style: empSans(12.5, color: empMuted)),
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
