import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// CATALOG ACCESS — admin side of employee catalog addition permissions.
//   Reads the v_catalog_access_requests view (effective_status reports expired
//   on its own — the table row stays 'approved', so never read raw status).
//   All writes go through DB functions: decide_catalog_access,
//   revoke_catalog_access. Only admins can approve/deny/remove; the view's RLS
//   already limits cashiers to their own rows.
// ============================================================================

class CatalogAccessException implements Exception {
  final String message;
  const CatalogAccessException(this.message);
  @override
  String toString() => message;
}

final catalogAccessPendingCount = ValueNotifier<int>(0);
final catalogAccessInitialTab = ValueNotifier<int>(-1);

class CatalogAccessRequest {
  final String id;
  final String userId;
  final String userName;
  final String branchId;
  final String branchName;
  final String reason;
  final DateTime requestedAt;
  final DateTime? decidedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;
  final String? decidedByName;
  final String? revokedByName;
  final String effectiveStatus; // pending | approved | denied | revoked | expired
  final bool endedByCashier;

  const CatalogAccessRequest({
    required this.id,
    required this.userId,
    required this.userName,
    required this.branchId,
    required this.branchName,
    required this.reason,
    required this.requestedAt,
    required this.decidedAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.decidedByName,
    required this.revokedByName,
    required this.effectiveStatus,
    required this.endedByCashier,
  });

  factory CatalogAccessRequest.fromMap(Map r) {
    DateTime? dt(Object? v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v as String);
      } catch (_) {
        return null;
      }
    }

    final revokedBy = r['revoked_by_name'] as String?;
    return CatalogAccessRequest(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      userName: (r['full_name'] as String?) ?? 'Unknown staff',
      branchId: r['branch_id'] as String,
      branchName: (r['branch_name'] as String?) ?? 'Unknown branch',
      reason: (r['reason'] as String?)?.trim() ?? '',
      requestedAt: dt(r['requested_at']) ?? DateTime.now(),
      decidedAt: dt(r['decided_at']),
      expiresAt: dt(r['expires_at']),
      revokedAt: dt(r['revoked_at']),
      decidedByName: (r['decided_by_name'] as String?)?.trim().isNotEmpty == true
          ? (r['decided_by_name'] as String).trim()
          : null,
      revokedByName: revokedBy?.trim().isNotEmpty == true ? revokedBy!.trim() : null,
      effectiveStatus: (r['effective_status'] as String?) ?? 'pending',
      endedByCashier: (r['revoked_by_id'] as String?) != null &&
          r['revoked_by_id'] == r['user_id'],
    );
  }

  bool get isPending => effectiveStatus == 'pending';
  bool get isActive => effectiveStatus == 'approved';

  bool get isStaleUnlimited {
    if (!isActive || expiresAt != null) return false;
    final since = decidedAt ?? requestedAt;
    return DateTime.now().difference(since) > const Duration(hours: 24);
  }

  Duration? get remaining {
    if (!isActive || expiresAt == null) return null;
    return expiresAt!.difference(DateTime.now());
  }

  String countdownLabel() {
    final left = remaining;
    if (left == null) return 'Until removed';
    if (left.isNegative) return 'Expired';
    if (left.inDays >= 1) return 'Ends in ${left.inDays}d ${left.inHours % 24}h';
    if (left.inHours >= 1) return 'Ends in ${left.inHours}h ${left.inMinutes % 60}m';
    return 'Ends in ${left.inMinutes}m';
  }

  String outcomeLabel() {
    switch (effectiveStatus) {
      case 'denied':
        return 'Denied';
      case 'revoked':
        return endedByCashier ? 'Ended by staff' : 'Removed';
      case 'expired':
        return 'Expired';
      case 'approved':
        return 'Active';
      default:
        return 'Pending';
    }
  }
}

class CatalogAccessRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<CatalogAccessRequest>> fetchAll() async {
    final rows = await _client.from('v_catalog_access_requests').select().limit(400) as List;
    return rows.map((r) => CatalogAccessRequest.fromMap(r as Map)).toList();
  }

  Future<void> decide({required String requestId, required bool approve, int? hours}) async {
    try {
      await _client.rpc('decide_catalog_access', params: {
        'p_request_id': requestId,
        'p_approve': approve,
        'p_hours': ?hours,
      });
    } on PostgrestException catch (e) {
      throw CatalogAccessException(e.message);
    }
  }

  Future<void> revoke({required String requestId}) async {
    try {
      await _client.rpc('revoke_catalog_access', params: {'p_request_id': requestId});
    } on PostgrestException catch (e) {
      throw CatalogAccessException(e.message);
    }
  }
}
