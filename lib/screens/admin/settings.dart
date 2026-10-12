import 'package:flutter/material.dart';

import '../../widgets/adminShell.dart';
import 'adminui.dart';
import 'branch.dart';
import 'user.dart';

// ============================================================================
// ADMIN SETTINGS
//   Management links switch active tab in the shell so the navigation bar
//   stays visible across all screens with the active screen highlighted.
// ============================================================================

class AdminSettingsScreen extends StatelessWidget {
  final String userName;
  const AdminSettingsScreen({super.key, this.userName = ''});

  void _openBranches(BuildContext context) {
    final scope = AdminShellScope.of(context);
    if (scope != null) {
      scope.selectTab(2);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BranchesScreen(embedded: false)));
    }
  }

  void _openUsers(BuildContext context) {
    final scope = AdminShellScope.of(context);
    if (scope != null) {
      scope.selectTab(3);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const UsersScreen(embedded: false)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= kWideContentBreakpoint;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 18, wide ? 32 : 18, 32),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Settings', style: sans(24, weight: FontWeight.w700, color: kInk)),
                      const SizedBox(height: 3),
                      Text('Manage your shops and the people who work in them.',
                          style: sans(13.5, color: kInkMuted)),
                      const SizedBox(height: 22),
                      Text('Management', style: sans(12, weight: FontWeight.w700, color: kInk)),
                      const SizedBox(height: 8),
                      const Divider(height: 1, color: kBorder),
                      _SettingsTile(
                        icon: Icons.storefront_outlined,
                        title: 'Branches',
                        subtitle: 'Add shops, edit details, deactivate or delete',
                        onTap: () => _openBranches(context),
                      ),
                      const Divider(height: 1, color: kBorder),
                      _SettingsTile(
                        icon: Icons.people_outline,
                        title: 'Users',
                        subtitle: 'Approve sign-ups, assign branches, remove accounts',
                        onTap: () => _openUsers(context),
                      ),
                      const Divider(height: 1, color: kBorder),
                      const SizedBox(height: 32),
                      Text('Account', style: sans(12, weight: FontWeight.w700, color: kInk)),
                      const SizedBox(height: 8),
                      const Divider(height: 1, color: kBorder),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            Avatar(name: userName),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    userName.trim().isNotEmpty ? userName : 'Signed in',
                                    overflow: TextOverflow.ellipsis,
                                    style: sans(14, weight: FontWeight.w600, color: kInk),
                                  ),
                                  Text('Admin', style: sans(12, color: kInkMuted)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: kBorder),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: kInkMuted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: sans(14, weight: FontWeight.w600, color: kInk)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: sans(12.5, color: kInkMuted)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: kInkMuted),
          ],
        ),
      ),
    );
  }
}