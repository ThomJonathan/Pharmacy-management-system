import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeHomeRepo.dart';
import 'employeeUi.dart';
import 'expenseScreen.dart';

// ============================================================================
// EMPLOYEE HOME — first screen for branch staff (cashier-first).
//   Read-only apart from its shortcuts and expense recording. Everything
//   is live and limited to the user's own branch. Clean, minimal design
//   hierarchy using typography, alignment, and hairline dividers.
// ============================================================================

class EmployeeHomeScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const EmployeeHomeScreen({
    super.key,
    required this.user,
    required this.branchName,
  });

  @override
  State<EmployeeHomeScreen> createState() => _EmployeeHomeScreenState();
}

String _greeting() {
  final h = DateTime.now().hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

String _todayLabel() {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final n = DateTime.now();
  return '${days[n.weekday - 1]} ${n.day} ${months[n.month - 1]} ${n.year}';
}

String _timeLabel(String iso) {
  try {
    final d = DateTime.parse(iso).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return '';
  }
}

String _methodLabel(String m) {
  switch (m) {
    case 'cash':
      return 'Cash';
    case 'airtel_money':
      return 'Airtel Money';
    case 'tnm_mpamba':
      return 'TNM Mpamba';
    case 'mobile_money':
      return 'Mobile money';
    case 'card':
      return 'Card';
    case 'credit':
      return 'Credit';
    default:
      return m.isEmpty ? '—' : m;
  }
}

Future<T?> _showEmpSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
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
          constraints: const BoxConstraints(maxWidth: 520),
          child: builder(ctx),
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

class _EmployeeHomeScreenState extends State<EmployeeHomeScreen> {
  final _repo = EmployeeHomeRepository();
  final _lookupCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  EmployeeHomeBundle? _data;
  bool _loadedOnce = false;
  bool _wasSelected = false;

  String _lookupQuery = '';
  List<LookupItem> _lookupResults = [];
  bool _lookupLoading = false;

  /// Branch price/availability index, loaded once and filtered locally so
  /// typing shows results instantly instead of waiting for a network query.
  List<LookupItem>? _lookupIndex;
  bool _lookupIndexLoading = false;
  String? _lookupIndexError;

  static const int _lookupResultLimit = 20;

  bool get _isStock => widget.user.role == 'stock_controller';
  bool get _isManager => widget.user.role == 'manager';

  @override
  void initState() {
    super.initState();
    _load();
    // Start loading the lookup index in the background right away so the
    // first keystroke already has data to search.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadLookupIndex();
    });
  }

  @override
  void dispose() {
    _lookupCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 0;
    if (selected && !_wasSelected && _loadedOnce) {
      _load(silent: true);
      // Keep availability/prices fresh after a sale without making the user
      // wait: the existing index stays usable while this refreshes.
      _loadLookupIndex();
    }
    _wasSelected = selected;
  }

  Future<void> _load({bool silent = false}) async {
    final branchId = widget.user.branchId;
    if (branchId == null) {
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
      final data = await _repo.fetchHome(
        branchId: branchId,
        role: widget.user.role,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
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

  /// Loads (or silently refreshes) the branch lookup index. Runs separately
  /// from the home bundle so a slow lookup never blocks the dashboard.
  Future<void> _loadLookupIndex() async {
    final branchId = widget.user.branchId;
    if (branchId == null || _lookupIndexLoading) return;
    setState(() {
      _lookupIndexLoading = true;
      _lookupIndexError = null;
      if (_lookupIndex == null && _lookupQuery.trim().length >= 2) {
        _lookupLoading = true;
      }
    });
    try {
      final index = await _repo.lookupIndex(branchId: branchId);
      if (!mounted) return;
      setState(() {
        _lookupIndex = index;
        _lookupIndexLoading = false;
        _lookupIndexError = null;
        _lookupResults = _matchesFor(_lookupQuery);
        _lookupLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lookupIndexLoading = false;
        // Keep serving the previous index if a background refresh fails.
        if (_lookupIndex == null) _lookupIndexError = e.toString();
        _lookupLoading = false;
      });
    }
  }

  List<LookupItem> _matchesFor(String query) {
    final index = _lookupIndex;
    final term = query.trim().toLowerCase();
    if (index == null || term.length < 2) return const [];
    final out = <LookupItem>[];
    for (final item in index) {
      if (item.name.toLowerCase().contains(term)) {
        out.add(item);
        if (out.length >= _lookupResultLimit) break;
      }
    }
    return out;
  }

  /// Filters the preloaded index in memory — no network call per keystroke.
  void _runLookup(String q) {
    setState(() {
      _lookupQuery = q;
      if (_lookupIndex != null) {
        _lookupResults = _matchesFor(q);
        _lookupLoading = false;
      } else {
        _lookupResults = const [];
        _lookupLoading = _lookupIndexLoading;
      }
    });
    final term = q.trim();
    if (term.length >= 2 &&
        _lookupIndex == null &&
        !_lookupIndexLoading &&
        _lookupIndexError == null) {
      _loadLookupIndex();
    }
  }

  Future<void> _openReceipt(RecentSale s) async {
    await _showEmpSheet<void>(
      context,
      builder: (_) => EmpSheetFrame(
        title: 'Receipt ${s.receipt}',
        subtitle: '${_timeLabel(s.time)} · ${_methodLabel(s.method)}',
        child: FutureBuilder<Receipt>(
          future: _repo.receipt(s.id),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: CircularProgressIndicator(color: empPrimary),
                ),
              );
            }
            if (snap.hasError || !snap.hasData) {
              return Text(
                'Couldn’t load the receipt.',
                style: empSans(13, color: empDanger),
              );
            }
            final r = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final l in r.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.itemName,
                                style: empSans(
                                  13.5,
                                  weight: FontWeight.w600,
                                  color: empInk,
                                ),
                              ),
                              Text(
                                '${empQty(l.qty)} × ${empMk(l.unitPrice)}',
                                style: empSans(12, color: empMuted),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          empMk(l.subtotal),
                          style: empMono(
                            13,
                            weight: FontWeight.w600,
                            color: empInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 16, color: empBorder),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total',
                        style: empSans(
                          14,
                          weight: FontWeight.w700,
                          color: empInk,
                        ),
                      ),
                    ),
                    Text(
                      empMk(r.total),
                      style: empMono(
                        15,
                        weight: FontWeight.w700,
                        color: empInk,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Paid ${empMk(r.paid)}${r.cashier.isNotEmpty ? ' · cashier: ${r.cashier}' : ''}',
                  style: empSans(12, color: empMuted),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPaymentSheet() async {
    final branchId = widget.user.branchId;
    if (branchId == null) return;
    final done = await _showEmpSheet<bool>(
      context,
      builder: (_) => _PaymentSheet(repo: _repo, branchId: branchId),
    );
    if (done == true && mounted) {
      await _load(silent: true);
      if (mounted) empToast(context, 'Payment recorded.');
    }
  }

  // ---- Build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: empPrimary,
          onRefresh: () => _load(silent: true),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= empWideBreakpoint;
              return SingleChildScrollView(
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

  Widget _body(bool wide) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (_error != null || _data == null) {
      return EmpEmpty(
        icon: Icons.error_outline,
        title: 'Couldn’t load Home',
        message: _error ?? 'Something went wrong.',
        action: OutlinedButton(
          onPressed: _load,
          style: empOutlineButton(height: 36),
          child: const Text('Retry'),
        ),
      );
    }
    final d = _data!;

    final greeting = _Greeting(
      userName: widget.user.fullName,
      branchName: widget.branchName,
      role: widget.user.role,
    );
    final action = _MainAction(
      isStock: _isStock,
      branchId: widget.user.branchId,
      onExpenseSaved: () => _load(silent: true),
    );
    final summary = _SummaryBlock(
      data: d,
      wide: wide,
      showManagerExtras: _isManager,
    );
    final lookup = _LookupBlock(
      controller: _lookupCtrl,
      loading: _lookupLoading,
      query: _lookupQuery,
      results: _lookupResults,
      onChanged: _runLookup,
      error: _lookupIndexError,
      onRetry: _loadLookupIndex,
    );
    final recent = _isStock
        ? _MovementsBlock(moves: d.recentMoves)
        : _RecentSalesBlock(sales: d.recentSales, onTap: _openReceipt);
    final owing = _OwingBlock(
      data: d,
      onPay: _openPaymentSheet,
      onOpenReports: () => EmployeeShell.switchTo(context, 3),
    );

    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: greeting),
              action,
            ],
          ),
          const SizedBox(height: 20),
          summary,
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: recent,
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    lookup,
                    const SizedBox(height: 24),
                    owing,
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        greeting,
        const SizedBox(height: 14),
        action,
        const SizedBox(height: 18),
        summary,
        const SizedBox(height: 20),
        lookup,
        const SizedBox(height: 20),
        recent,
        const SizedBox(height: 20),
        owing,
      ],
    );
  }
}

// ============================================================================
// GREETING + MAIN ACTIONS
// ============================================================================

class _Greeting extends StatelessWidget {
  final String userName;
  final String branchName;
  final String role;
  const _Greeting({
    required this.userName,
    required this.branchName,
    required this.role,
  });

  String get _roleLabel {
    switch (role) {
      case 'stock_controller':
        return 'Stock controller';
      case 'cashier':
        return 'Cashier';
      case 'manager':
        return 'Manager';
      case 'admin':
        return 'Admin';
      default:
        return role;
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = userName.trim().isEmpty
        ? 'Staff'
        : userName.trim().split(' ').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_greeting()}, $first',
          style: empSans(22, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 3),
        Text(
          '${branchName.isEmpty ? 'Your branch' : branchName} · $_roleLabel · ${_todayLabel()}',
          style: empSans(12.5, color: empMuted),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _MainAction extends StatelessWidget {
  final bool isStock;
  final String? branchId;
  final VoidCallback onExpenseSaved;
  const _MainAction({
    required this.isStock,
    required this.branchId,
    required this.onExpenseSaved,
  });

  Future<void> _newExpense(BuildContext context) async {
    final bid = branchId;
    if (bid == null) {
      empToast(context, 'No branch assigned to this account yet.', error: true);
      return;
    }
    final saved = await showRecordExpenseSheet(context, branchId: bid);
    if (saved == true && context.mounted) {
      onExpenseSaved();
      empToast(context, 'Expense recorded.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: () =>
              EmployeeShell.switchTo(context, isStock ? 2 : 1),
          style: empPrimaryButton(height: 40),
          icon: Icon(
            isStock ? Icons.add_box_outlined : Icons.point_of_sale_outlined,
            size: 17,
          ),
          label: Text(isStock ? 'Receive stock' : 'New sale'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => _newExpense(context),
          style: empOutlineButton(height: 40),
          icon: const Icon(Icons.add_card_outlined, size: 16),
          label: const Text('Record expense'),
        ),
      ],
    );
  }
}

// ============================================================================
// SUMMARY METRIC BAND (clean typography + dividers, no card containers)
// ============================================================================

class _SummaryBlock extends StatelessWidget {
  final EmployeeHomeBundle data;
  final bool wide;
  final bool showManagerExtras;
  const _SummaryBlock({
    required this.data,
    required this.wide,
    required this.showManagerExtras,
  });

  @override
  Widget build(BuildContext context) {
    if (wide) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: empBorder),
            bottom: BorderSide(color: empBorder),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: EmpStatMetric(
                label: 'Sales today',
                value: '${data.salesCount}',
                sub: '${data.salesCount == 1 ? 'sale' : 'sales'} recorded',
              ),
            ),
            Container(width: 1, height: 48, color: empBorder),
            const SizedBox(width: 20),
            Expanded(
              flex: 3,
              child: EmpStatMetric(
                label: 'Total sales today',
                value: empMk(data.salesTotal),
                sub: 'gross turnover',
                valueColor: empPrimary,
                mono: true,
              ),
            ),
            Container(width: 1, height: 48, color: empBorder),
            const SizedBox(width: 20),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Payment split', style: empSans(12, color: empMuted)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      _splitItem('Cash', data.cashTotal),
                      _splitItem('Airtel', data.airtelTotal),
                      _splitItem('Mpamba', data.mpambaTotal),
                      _splitItem('Credit', data.creditTotal),
                      if (data.cardTotal > 0) _splitItem('Card', data.cardTotal),
                    ],
                  ),
                ],
              ),
            ),
            if (showManagerExtras) ...[
              Container(width: 1, height: 48, color: empBorder),
              const SizedBox(width: 20),
              Expanded(
                flex: 3,
                child: EmpStatMetric(
                  label: 'Gross profit',
                  value: empMk(data.grossToday),
                  sub: 'revenue − cogs',
                  valueColor: empSuccess,
                  mono: true,
                ),
              ),
              Container(width: 1, height: 48, color: empBorder),
              const SizedBox(width: 20),
              Expanded(
                flex: 3,
                child: EmpStatMetric(
                  label: 'Expenses today',
                  value: empMk(data.expensesToday),
                  sub: 'branch outgoings',
                  valueColor: empDanger,
                  mono: true,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // Mobile layout
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: empBorder),
          bottom: BorderSide(color: empBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: EmpStatMetric(
                  label: 'Sales today',
                  value: '${data.salesCount}',
                  sub: '${data.salesCount == 1 ? 'sale' : 'sales'}',
                ),
              ),
              Container(width: 1, height: 44, color: empBorder),
              const SizedBox(width: 16),
              Expanded(
                child: EmpStatMetric(
                  label: 'Total sales',
                  value: empMk(data.salesTotal),
                  sub: 'today’s turnover',
                  valueColor: empPrimary,
                  mono: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: empBorder),
          const SizedBox(height: 10),
          Text('Payment breakdown', style: empSans(11.5, color: empMuted)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _splitItem('Cash', data.cashTotal),
              _splitItem('Airtel', data.airtelTotal),
              _splitItem('Mpamba', data.mpambaTotal),
              _splitItem('Credit', data.creditTotal),
              if (data.cardTotal > 0) _splitItem('Card', data.cardTotal),
            ],
          ),
          if (showManagerExtras) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: empBorder),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: EmpStatMetric(
                    label: 'Gross profit',
                    value: empMk(data.grossToday),
                    sub: 'branch profit',
                    valueColor: empSuccess,
                    mono: true,
                  ),
                ),
                Container(width: 1, height: 40, color: empBorder),
                const SizedBox(width: 16),
                Expanded(
                  child: EmpStatMetric(
                    label: 'Expenses today',
                    value: empMk(data.expensesToday),
                    sub: 'branch spent',
                    valueColor: empDanger,
                    mono: true,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _splitItem(String label, double amount) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: empSans(12, color: empMuted)),
        Text(
          empMk(amount),
          style: empMono(12, weight: FontWeight.w600, color: empInk),
        ),
      ],
    );
  }
}

// ============================================================================
// QUICK ITEM LOOKUP
// ============================================================================

class _LookupBlock extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final String query;
  final List<LookupItem> results;
  final ValueChanged<String> onChanged;
  final String? error;
  final VoidCallback? onRetry;
  const _LookupBlock({
    required this.controller,
    required this.loading,
    required this.query,
    required this.results,
    required this.onChanged,
    this.error,
    this.onRetry,
  });

  String _price(double min, double max) =>
      (min == max) ? empMk(min) : '${empMk(min)} – ${empMk(max)}';

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EmpSectionHeader(
          title: 'Quick price lookup',
          subtitle: 'Search prices & availability without starting a sale',
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          onChanged: onChanged,
          style: empSans(14, color: empInk),
          textInputAction: TextInputAction.search,
          decoration: empField('Type a medicine or item name…').copyWith(
            prefixIcon: const Icon(Icons.search, size: 18, color: empMuted),
            suffixIcon: q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 17, color: empMuted),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
        if (loading) ...[
          const SizedBox(height: 12),
          const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: empPrimary,
              ),
            ),
          ),
        ] else if (q.length >= 2) ...[
          const SizedBox(height: 8),
          if (error != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: empDangerTint,
                border: Border.all(color: empDanger),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 17,
                    color: empDanger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Quick lookup could not load. Check your connection and try again.',
                      style: empSans(12, color: empInk),
                    ),
                  ),
                  if (onRetry != null)
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: empPrimary,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            )
          else if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No items found matching “$q”.',
                style: empSans(12.5, color: empMuted),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: empBorder),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                children: List.generate(results.length, (i) {
                  final r = results[i];
                  final isLast = i == results.length - 1;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: isLast
                          ? null
                          : const Border(bottom: BorderSide(color: empBorder)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.name,
                                style: empSans(
                                  13.5,
                                  weight: FontWeight.w600,
                                  color: empInk,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Retail: ${_price(r.retailMin, r.retailMax)}'
                                '${r.wholesaleMin != null ? ' · Wholesale: ${_price(r.wholesaleMin!, r.wholesaleMax!)}' : ''}',
                                style: empSans(12, color: empMuted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${empQty(r.qty)} left',
                          style: empMono(
                            12.5,
                            weight: FontWeight.w700,
                            color: r.qty <= 5 ? empWarn : empPrimary,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
        ],
      ],
    );
  }
}

// ============================================================================
// RECENT SALES TODAY
// ============================================================================

class _RecentSalesBlock extends StatelessWidget {
  final List<RecentSale> sales;
  final ValueChanged<RecentSale> onTap;
  const _RecentSalesBlock({required this.sales, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EmpSectionHeader(
          title: 'Recent sales today (${sales.length})',
        ),
        const SizedBox(height: 10),
        if (sales.isEmpty)
          const EmpEmpty(
            icon: Icons.point_of_sale_outlined,
            title: 'No sales recorded yet',
            message: 'Completed sales today will appear here.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: List.generate(sales.length, (i) {
                final s = sales[i];
                final isLast = i == sales.length - 1;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onTap(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        border: isLast
                            ? null
                            : const Border(
                                bottom: BorderSide(color: empBorder),
                              ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.receipt,
                                  style: empSans(
                                    13.5,
                                    weight: FontWeight.w600,
                                    color: empInk,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  '${_timeLabel(s.time)} · ${s.itemCount} ${s.itemCount == 1 ? 'item' : 'items'} · ${_methodLabel(s.method)}',
                                  style: empSans(11.5, color: empMuted),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            empMk(s.total),
                            style: empMono(
                              13.5,
                              weight: FontWeight.w700,
                              color: empInk,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: empMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// RECENT STOCK MOVEMENTS (for stock controllers)
// ============================================================================

class _MovementsBlock extends StatelessWidget {
  final List<BranchMove> moves;
  const _MovementsBlock({required this.moves});

  String _label(String t) {
    switch (t) {
      case 'purchase_in':
        return 'Received';
      case 'sale_out':
        return 'Sold';
      case 'adjustment_out':
        return 'Adjusted out';
      case 'adjustment_in':
        return 'Adjusted in';
      case 'opening_stock':
        return 'Opening';
      default:
        return t;
    }
  }

  bool _isOut(String t) => t == 'sale_out' || t == 'adjustment_out';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EmpSectionHeader(
          title: 'Recent stock movements (${moves.length})',
        ),
        const SizedBox(height: 10),
        if (moves.isEmpty)
          const EmpEmpty(
            icon: Icons.swap_horiz_outlined,
            title: 'No movements yet',
            message: 'Stock deliveries and sales will show here.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: List.generate(moves.length, (i) {
                final m = moves[i];
                final out = _isOut(m.type);
                final isLast = i == moves.length - 1;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: isLast
                        ? null
                        : const Border(bottom: BorderSide(color: empBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.itemName,
                              style: empSans(
                                13.5,
                                weight: FontWeight.w600,
                                color: empInk,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              '${_label(m.type)} · ${_timeLabel(m.time)}',
                              style: empSans(11.5, color: empMuted),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${out ? '−' : '+'}${empQty(m.qty)}',
                        style: empMono(
                          13,
                          weight: FontWeight.w700,
                          color: out ? empDanger : empSuccess,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// CUSTOMERS OWING & PAYMENT
// ============================================================================

class _OwingBlock extends StatelessWidget {
  final EmployeeHomeBundle data;
  final VoidCallback onPay;
  final VoidCallback onOpenReports;
  const _OwingBlock({
    required this.data,
    required this.onPay,
    required this.onOpenReports,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EmpSectionHeader(
          title: 'Customer debts',
          action: data.owingCount > 0
              ? TextButton(
                  onPressed: onOpenReports,
                  style: TextButton.styleFrom(
                    foregroundColor: empPrimary,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text('View list', style: empSans(12, weight: FontWeight.w600, color: empPrimary)),
                )
              : null,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: empBorder),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.owingCount == 0
                    ? 'All customer accounts are clear'
                    : '${data.owingCount} ${data.owingCount == 1 ? 'customer owes' : 'customers owe'} ${empMk(data.owingTotal)}',
                style: empSans(
                  13.5,
                  weight: FontWeight.w700,
                  color: data.owingCount == 0 ? empInk : empDanger,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Credit balances outstanding at this branch',
                style: empSans(12, color: empMuted),
              ),
              if (data.owingCount > 0) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onPay,
                  style: empOutlineButton(height: 36),
                  icon: const Icon(Icons.payments_outlined, size: 16),
                  label: const Text('Record payment'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  final EmployeeHomeRepository repo;
  final String branchId;
  const _PaymentSheet({required this.repo, required this.branchId});

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  List<OwingCustomer> _customers = [];
  String? _customerId;
  final _amountCtrl = TextEditingController();
  String _method = 'cash';
  bool _loading = true;
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.repo.owingCustomers(branchId: widget.branchId);
      if (!mounted) return;
      setState(() {
        _customers = list;
        _loading = false;
        if (list.isNotEmpty) {
          _customerId = list.first.id;
          _amountCtrl.text = list.first.balance.toStringAsFixed(0);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.of(context).pop();
    }
  }

  void _onCustomer(String? id) {
    setState(() => _customerId = id);
    final c = _customers.where((x) => x.id == id).toList();
    if (c.isNotEmpty) _amountCtrl.text = c.first.balance.toStringAsFixed(0);
  }

  Future<void> _submit() async {
    if (_customerId == null) {
      setState(() => _formError = 'Pick a customer first.');
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _formError = 'Enter an amount above zero.');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.recordPayment(
        branchId: widget.branchId,
        customerId: _customerId!,
        amount: amount,
        method: _method,
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
    return EmpSheetFrame(
      title: 'Record payment',
      subtitle: 'Customer settling credit balance.',
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: CircularProgressIndicator(color: empPrimary),
              ),
            )
          : Column(
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
                    child: DropdownButton<String>(
                      value: _customerId,
                      isExpanded: true,
                      style: empSans(14, color: empInk),
                      items: [
                        for (final c in _customers)
                          DropdownMenuItem(
                            value: c.id,
                            child: Text('${c.name} · owes ${empMk(c.balance)}'),
                          ),
                      ],
                      onChanged: _onCustomer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: empSans(14, color: empInk),
                  decoration: empField('Amount (MK)'),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: empBorder),
                    borderRadius: BorderRadius.circular(4),
                    color: Colors.white,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _method,
                      isExpanded: true,
                      style: empSans(14, color: empInk),
                      items: const [
                        DropdownMenuItem(value: 'cash', child: Text('Cash')),
                        DropdownMenuItem(
                          value: 'airtel_money',
                          child: Text('Airtel Money'),
                        ),
                        DropdownMenuItem(
                          value: 'tnm_mpamba',
                          child: Text('TNM Mpamba'),
                        ),
                        DropdownMenuItem(value: 'card', child: Text('Card')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _method = v);
                      },
                    ),
                  ),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _formError!,
                    style: empSans(
                      12.5,
                      weight: FontWeight.w600,
                      color: empDanger,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  style: empPrimaryButton(),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save payment'),
                ),
              ],
            ),
    );
  }
}
