import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'adminui.dart';
import 'catalogAccessRepo.dart';

// ============================================================================
// CATALOG ACCESS — admin side of employee catalog permissions.
//   Pending: Approve (duration dialog) / Deny (confirm).
//   Active: countdown or "Until removed", Remove access (confirm).
//   History: every outcome + who decided, branch/staff/status/date filters.
// ============================================================================

String _fmtWhen(DateTime dt) => DateFormat('d MMM yyyy, HH:mm').format(dt.toLocal());
String _fmtDay(DateTime dt) => DateFormat('d MMM yyyy').format(dt.toLocal());

class CatalogAccessSection extends StatefulWidget {
  final int initialTab;
  const CatalogAccessSection({super.key, this.initialTab = 0});

  @override
  State<CatalogAccessSection> createState() => _CatalogAccessSectionState();
}

class _CatalogAccessSectionState extends State<CatalogAccessSection> {
  final _repo = CatalogAccessRepository();
  List<CatalogAccessRequest> _all = [];
  bool _loading = true;
  String? _error;
  int _tab = 0;

  // History filters
  String? _branch;
  String _staff = '';
  String _status = 'all';
  DateTime? _day;
  final _staffCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 2);
    _load(silent: true);
  }

  @override
  void dispose() {
    _staffCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await _repo.fetchAll();
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
        _error = null;
      });
      catalogAccessPendingCount.value = rows.where((r) => r.isPending).length;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<CatalogAccessRequest> get _pending {
    final list = _all.where((r) => r.isPending).toList();
    list.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return list;
  }

  List<CatalogAccessRequest> get _active {
    final list = _all.where((r) => r.isActive).toList();
    list.sort((a, b) {
      final ae = a.expiresAt;
      final be = b.expiresAt;
      if (ae == null && be == null) return 0;
      if (ae == null) return 1;
      if (be == null) return -1;
      return ae.compareTo(be);
    });
    return list;
  }

  List<CatalogAccessRequest> get _history {
    final q = _staff.trim().toLowerCase();
    final list = _all.where((r) {
      if (r.isPending) return false;
      if (_branch != null && r.branchId != _branch) return false;
      if (q.isNotEmpty && !r.userName.toLowerCase().contains(q)) return false;
      switch (_status) {
        case 'active':
          if (!r.isActive) return false;
        case 'denied':
          if (r.effectiveStatus != 'denied') return false;
        case 'removed':
          if (!(r.effectiveStatus == 'revoked' && !r.endedByCashier)) return false;
        case 'ended':
          if (!(r.effectiveStatus == 'revoked' && r.endedByCashier)) return false;
        case 'expired':
          if (r.effectiveStatus != 'expired') return false;
      }
      if (_day != null) {
        final d = r.decidedAt ?? r.requestedAt;
        if (d.year != _day!.year || d.month != _day!.month || d.day != _day!.day) {
          return false;
        }
      }
      return true;
    }).toList();
    list.sort((a, b) => (b.decidedAt ?? b.requestedAt).compareTo(a.decidedAt ?? a.requestedAt));
    return list;
  }

  Future<void> _approve(CatalogAccessRequest req) async {
    final hours = await showAdaptiveSheet<int?>(
      context,
      builder: (_) => _DurationSheet(cashierName: req.userName),
    );
    if (hours == -1) return; // cancelled
    try {
      await _repo.decide(
        requestId: req.id,
        approve: true,
        hours: hours == null || hours == 0 ? null : hours,
      );
      await _load(silent: true);
      if (mounted) {
        showToast(
          context,
          hours == null || hours == 0
              ? 'Catalog access granted to ${req.userName}.'
              : 'Catalog access granted to ${req.userName} for ${hours}h.',
        );
      }
    } on CatalogAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _deny(CatalogAccessRequest req) async {
    final ok = await showConfirm(
      context,
      title: 'Deny catalog request?',
      message: '${req.userName} won’t be able to add new products to the catalog.',
      confirmLabel: 'Deny request',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.decide(requestId: req.id, approve: false);
      await _load(silent: true);
      if (mounted) showToast(context, 'Request denied.');
    } on CatalogAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _revoke(CatalogAccessRequest req) async {
    final ok = await showConfirm(
      context,
      title: 'End catalog access for ${req.userName}?',
      message: 'They will immediately stop being able to add new products to the catalog.',
      confirmLabel: 'End access',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.revoke(requestId: req.id);
      await _load(silent: true);
      if (mounted) showToast(context, 'Access removed for ${req.userName}.');
    } on CatalogAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 60),
        child: Center(child: CircularProgressIndicator(color: kPrimary)),
      );
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: _load);
    }

    final pCount = _pending.length;
    final aCount = _active.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              FilterPill(
                label: pCount > 0 ? 'Pending ($pCount)' : 'Pending',
                selected: _tab == 0,
                onTap: () => setState(() => _tab = 0),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: aCount > 0 ? 'Active ($aCount)' : 'Active',
                selected: _tab == 1,
                onTap: () => setState(() => _tab = 1),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: 'History (${_history.length})',
                selected: _tab == 2,
                onTap: () => setState(() => _tab = 2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (_tab == 0) _pendingView(),
        if (_tab == 1) _activeView(),
        if (_tab == 2) _historyView(),
      ],
    );
  }

  Widget _pendingView() {
    final list = _pending;
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline,
        title: 'No pending catalog requests',
        message: 'When an employee requests permission to add new products to the catalog, it will appear here.',
      );
    }
    return Column(
      children: [
        for (final r in list) ...[
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.userName, style: sans(15, weight: FontWeight.w600, color: kInk)),
                          const SizedBox(height: 2),
                          Text('${r.branchName} · ${_fmtWhen(r.requestedAt)}',
                              style: sans(12.5, color: kInkMuted)),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton(
                          onPressed: () => _deny(r),
                          style: outlineButtonStyle(height: 36),
                          child: const Text('Deny'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => _approve(r),
                          style: primaryButtonStyle(height: 36),
                          child: const Text('Approve'),
                        ),
                      ],
                    ),
                  ],
                ),
                if (r.reason.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Text('“${r.reason}”',
                        style: sans(13, color: kInkMuted).copyWith(fontStyle: FontStyle.italic)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _activeView() {
    final list = _active;
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.shield_outlined,
        title: 'No active catalog access',
        message: 'No employees currently have permission to add products to the catalog.',
      );
    }
    return Column(
      children: [
        for (final r in list) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(r.userName, style: sans(15, weight: FontWeight.w600, color: kInk)),
                          const SizedBox(width: 8),
                          StatusPill.active(r.countdownLabel()),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${r.branchName} · Granted ${_fmtWhen(r.decidedAt ?? r.requestedAt)}',
                        style: sans(12.5, color: kInkMuted),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () => _revoke(r),
                  style: outlineButtonStyle(height: 36),
                  child: const Text('End access'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _historyView() {
    final list = _history;
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.history,
        title: 'No catalog access history',
        message: 'Past requests and expired grants will appear here.',
      );
    }
    return Column(
      children: [
        for (final r in list) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.userName, style: sans(14, weight: FontWeight.w600, color: kInk)),
                      const SizedBox(height: 2),
                      Text(
                        '${r.branchName} · ${_fmtWhen(r.decidedAt ?? r.requestedAt)}',
                        style: sans(12, color: kInkMuted),
                      ),
                    ],
                  ),
                ),
                StatusPill.neutral(r.outcomeLabel()),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _DurationSheet extends StatefulWidget {
  final String cashierName;
  const _DurationSheet({required this.cashierName});

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  int? _hours = 4; // default 4 hours

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Grant catalog access',
      subtitle: 'Allow ${widget.cashierName} to add new products to the catalog.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Duration',
            style: sans(13, weight: FontWeight.w600, color: kInk),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in const [1, 4, 8, 24, 0])
                ChoiceChip(
                  label: Text(h == 0 ? 'Until removed' : '${h}h'),
                  selected: _hours == (h == 0 ? null : h),
                  selectedColor: kPrimary.withOpacity(0.15),
                  labelStyle: sans(
                    13,
                    weight: _hours == (h == 0 ? null : h) ? FontWeight.w600 : FontWeight.w500,
                    color: _hours == (h == 0 ? null : h) ? kPrimary : kInk,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      setState(() => _hours = h == 0 ? null : h);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(-1),
                  style: outlineButtonStyle(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_hours ?? 0),
                  style: primaryButtonStyle(),
                  child: const Text('Grant access'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
