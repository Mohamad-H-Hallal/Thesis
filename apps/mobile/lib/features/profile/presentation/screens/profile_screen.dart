import 'package:flutter/material.dart';

import '../../../../core/constants/design_tokens.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/section_header.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    required this.userName,
    required this.email,
    required this.role,
    required this.onLogout,
    super.key,
  });

  final String userName;
  final String email;
  final String role;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SectionHeader(
          title: 'Profile',
          subtitle: 'Identity and access overview',
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(
                      userName.isNotEmpty ? userName[0].toUpperCase() : 'U',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(email),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  Chip(label: Text(role)),
                  const Chip(label: Text('Session active')),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton.icon(
          onPressed: onLogout,
          icon: const Icon(Icons.logout),
          label: const Text('Logout'),
        ),
      ],
    );
  }
}
