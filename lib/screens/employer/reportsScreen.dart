import 'package:flutter/material.dart';

import '../../appUser.dart';
import 'employeeUi.dart';
import 'receipt.dart';
import 'reportsRepo.dart';
import 'saleRepo.dart';

class EmployeeReportsScreen extends StatefulWidget {
  final AppUser user;
  const EmployeeReportsScreen({super.key, required this.user});

  @override
  State<EmployeeReportsScreen> createState() => _EmployeeReportsScreenState();
}

class _EmployeeReportsScreenState extends State<EmployeeReportsScreen> {
  final _repo = EmployeeReportsRepository();
  final _search = TextEditingController();
  EmployeeReportPeriod _period = EmployeeReportPeriod.month();
  EmployeeReportData? _data;
  bool _loading = true;
  String? _error;
  int _tab = 0;
  bool _bySales = false;

  String? get _branchId => widget.user.branchId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bid = _branchId;
    if (bid == null) {
      setState(() {
        _loading = false;
        _error = 'No branch assigned to this account yet.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _repo.fetch(branchId: bid, period: _period);
      if (mounted) {
        setState(() {
          _data = value;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _money(double v) =>
      'MK ${v.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

  String _time(String raw) {
    final d = DateTime.tryParse(raw)?.toLocal();
    return d == null
        ? '—'
        : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _choosePeriod() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => EmpSheetFrame(
        title: 'Report period',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => Navigator.pop(ctx, 'today'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Today', style: empSans(14, weight: FontWeight.w600, color: empInk)),
              ),
            ),
            const Divider(height: 1, color: empBorder),
            InkWell(
              onTap: () => Navigator.pop(ctx, 'month'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('This month', style: empSans(14, weight: FontWeight.w600, color: empInk)),
              ),
            ),
            const Divider(height: 1, color: empBorder),
            InkWell(
              onTap: () => Navigator.pop(ctx, 'date'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Pick a specific date…', style: empSans(14, weight: FontWeight.w600, color: empInk)),
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == 'today') _period = EmployeeReportPeriod.today();
    if (choice == 'month') _period = EmployeeReportPeriod.month();
    if (choice == 'date' && mounted) {
      final d = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now(),
        initialDate: DateTime.now(),
      );
      if (d != null) _period = EmployeeReportPeriod.day(d);
    }
    if (choice != null) await _load();
  }

  Future<void> _receipt(EmployeeReportSale sale) async {
    try {
      final receipt = await SaleRepository().getReceipt(sale.id);
      await ReceiptService.printReceipt(receipt);
    } catch (e) {
      if (mounted) empToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: empPrimary,
          onRefresh: _load,
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Branch Reports',
                                    style: empSans(22, weight: FontWeight.w700, color: empInk),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _period.label,
                                    style: empSans(12.5, color: empMuted),
                                  ),
                                ],
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: _choosePeriod,
                              style: empOutlineButton(height: 38),
                              icon: const Icon(
                                Icons.calendar_today_outlined,
                                size: 15,
                              ),
                              label: Text(_period.label),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (_loading)
                          const Padding(
                            padding: EdgeInsets.all(60),
                            child: Center(
                              child: CircularProgressIndicator(color: empPrimary),
                            ),
                          )
                        else if (_error != null)
                          EmpEmpty(
                            icon: Icons.error_outline,
                            title: 'Couldn’t load reports',
                            message: _error!,
                            action: OutlinedButton(
                              onPressed: _load,
                              style: empOutlineButton(height: 36),
                              child: const Text('Retry'),
                            ),
                          )
                        else if (d != null) ...[
                          _summaryBand(d, wide),
                          const SizedBox(height: 20),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                EmpFilterPill(
                                  label: 'Sales (${d.sales.length})',
                                  selected: _tab == 0,
                                  onTap: () => setState(() => _tab = 0),
                                ),
                                const SizedBox(width: 8),
                                EmpFilterPill(
                                  label: 'Best sellers (${d.sellers.length})',
                                  selected: _tab == 1,
                                  onTap: () => setState(() => _tab = 1),
                                ),
                                const SizedBox(width: 8),
                                EmpFilterPill(
                                  label: 'Owing money (${d.debts.length})',
                                  selected: _tab == 2,
                                  onTap: () => setState(() => _tab = 2),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_tab == 0)
                            _sales(d)
                          else if (_tab == 1)
                            _best(d)
                          else
                            _debts(d),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _summaryBand(EmployeeReportData d, bool wide) {
    final debtsTotal = d.debts.fold(0.0, (s, x) => s + x.balance);
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
          children: [
            Expanded(
              child: EmpStatMetric(
                label: 'Transactions',
                value: '${d.sales.length}',
                sub: 'completed in period',
              ),
            ),
            Container(width: 1, height: 44, color: empBorder),
            const SizedBox(width: 20),
            Expanded(
              child: EmpStatMetric(
                label: 'Total revenue',
                value: _money(d.total),
                sub: 'gross sales recorded',
                valueColor: empPrimary,
                mono: true,
              ),
            ),
            Container(width: 1, height: 44, color: empBorder),
            const SizedBox(width: 20),
            Expanded(
              child: EmpStatMetric(
                label: 'Outstanding debt',
                value: _money(debtsTotal),
                sub: '${d.debts.length} customers owe',
                valueColor: debtsTotal > 0 ? empDanger : empInk,
                mono: true,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: empBorder),
          bottom: BorderSide(color: empBorder),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: EmpStatMetric(
                  label: 'Transactions',
                  value: '${d.sales.length}',
                  sub: 'completed',
                ),
              ),
              Container(width: 1, height: 40, color: empBorder),
              const SizedBox(width: 16),
              Expanded(
                child: EmpStatMetric(
                  label: 'Total revenue',
                  value: _money(d.total),
                  sub: 'gross sales',
                  valueColor: empPrimary,
                  mono: true,
                ),
              ),
            ],
          ),
          if (debtsTotal > 0) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: empBorder),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: EmpStatMetric(
                label: 'Outstanding debt',
                value: _money(debtsTotal),
                sub: '${d.debts.length} customers currently owe',
                valueColor: empDanger,
                mono: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sales(EmployeeReportData d) {
    if (d.sales.isEmpty) {
      return const EmpEmpty(
        icon: Icons.receipt_long_outlined,
        title: 'No sales in this period',
        message: 'No completed sales were found for the selected timeframe.',
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: List.generate(d.sales.length, (i) {
          final s = d.sales[i];
          final isLast = i == d.sales.length - 1;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _receipt(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: isLast ? null : const Border(bottom: BorderSide(color: empBorder)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 50,
                      child: Text(
                        _time(s.time),
                        style: empMono(12, color: empMuted),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.receipt,
                            style: empSans(13.5, weight: FontWeight.w600, color: empInk),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${s.cashier} · ${s.method}',
                            style: empSans(11.5, color: empMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _money(s.total),
                      style: empMono(13.5, weight: FontWeight.w700, color: empInk),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.print_outlined, size: 16, color: empMuted),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _best(EmployeeReportData d) {
    if (d.sellers.isEmpty) {
      return const EmpEmpty(
        icon: Icons.inventory_2_outlined,
        title: 'No item data',
        message: 'No item sales were recorded in this period.',
      );
    }

    final rows = d.sellers.toList()
      ..sort(
        (a, b) => _bySales
            ? b.sales.compareTo(a.sales)
            : b.quantity.compareTo(a.quantity),
      );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Rank by:', style: empSans(12.5, color: empMuted)),
            const SizedBox(width: 8),
            EmpFilterPill(
              label: 'Quantity sold',
              selected: !_bySales,
              onTap: () => setState(() => _bySales = false),
            ),
            const SizedBox(width: 6),
            EmpFilterPill(
              label: 'Transaction count',
              selected: _bySales,
              onTap: () => setState(() => _bySales = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: empBorder),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: List.generate(rows.length, (i) {
              final x = rows[i];
              final isLast = i == rows.length - 1;
              final qtyStr = x.quantity % 1 == 0 ? x.quantity.toInt().toString() : x.quantity.toString();
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: isLast ? null : const Border(bottom: BorderSide(color: empBorder)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${i + 1}.',
                        style: empMono(12, weight: FontWeight.w600, color: empMuted),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            x.name,
                            style: empSans(13.5, weight: FontWeight.w600, color: empInk),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            '${x.sales} separate ${x.sales == 1 ? 'sale' : 'sales'}',
                            style: empSans(11.5, color: empMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$qtyStr sold',
                      style: empMono(13, weight: FontWeight.w700, color: empPrimary),
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

  Widget _debts(EmployeeReportData d) {
    final q = _search.text.toLowerCase();
    final rows = d.debts
        .where((x) => x.name.toLowerCase().contains(q))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          style: empSans(14, color: empInk),
          decoration: empField('Search debtors by name…').copyWith(
            prefixIcon: const Icon(Icons.search, size: 18, color: empMuted),
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          EmpEmpty(
            icon: Icons.check_circle_outline,
            title: 'No outstanding balances',
            message: q.isEmpty ? 'All accounts are cleared.' : 'No debtor found matching “$q”.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: List.generate(rows.length, (i) {
                final x = rows[i];
                final isLast = i == rows.length - 1;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _customer(x),
                    child: Container(
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
                                  x.name,
                                  style: empSans(13.5, weight: FontWeight.w600, color: empInk),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  'Tap to view payments or record',
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
                                _money(x.balance),
                                style: empMono(13.5, weight: FontWeight.w700, color: empDanger),
                              ),
                              const SizedBox(height: 1),
                              Text('balance', style: empSans(10.5, color: empMuted)),
                            ],
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, size: 17, color: empMuted),
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

  Future<void> _customer(EmployeeDebt debt) async {
    final history = await _repo.payments(debt.id);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EmpSheetFrame(
        title: debt.name,
        subtitle: 'Outstanding balance: ${_money(debt.balance)}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text('No previous payments recorded.', style: empSans(12.5, color: empMuted)),
              )
            else ...[
              Text('Payment history', style: empSans(13, weight: FontWeight.w700, color: empInk)),
              const SizedBox(height: 8),
              for (final p in history)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('${p.date} · ${p.method}', style: empSans(12, color: empMuted)),
                      Text(_money(p.amount), style: empMono(12.5, weight: FontWeight.w600, color: empSuccess)),
                    ],
                  ),
                ),
              const Divider(height: 16, color: empBorder),
            ],
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                final amount = await _paymentDialog(debt);
                if (amount == null) return;
                await _load();
              },
              style: empPrimaryButton(height: 42),
              child: const Text('Record payment'),
            ),
          ],
        ),
      ),
    );
  }

  Future<double?> _paymentDialog(EmployeeDebt debt) async {
    final bid = _branchId;
    if (bid == null) return null;
    final ctrl = TextEditingController();
    String method = 'cash';
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          title: Text('Record payment', style: empSans(16, weight: FontWeight.w700, color: empInk)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Current balance: ${_money(debt.balance)}', style: empSans(13, color: empMuted)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                style: empSans(14, color: empInk),
                decoration: empField('Amount (MK)'),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: empBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: method,
                    isExpanded: true,
                    style: empSans(14, color: empInk),
                    items: const [
                      DropdownMenuItem(value: 'cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'airtel_money', child: Text('Airtel Money')),
                      DropdownMenuItem(value: 'tnm_mpamba', child: Text('TNM Mpamba')),
                      DropdownMenuItem(value: 'card', child: Text('Card')),
                    ],
                    onChanged: (v) => set(() => method = v!),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: empSans(13, color: empMuted)),
            ),
            FilledButton(
              onPressed: () async {
                final v = double.tryParse(ctrl.text);
                if (v == null || v <= 0 || v > debt.balance) return;
                await _repo.recordPayment(
                  branchId: bid,
                  customerId: debt.id,
                  amount: v,
                  method: method,
                );
                if (ctx.mounted) Navigator.pop(ctx, v);
              },
              style: empPrimaryButton(height: 38),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return amount;
  }
}
