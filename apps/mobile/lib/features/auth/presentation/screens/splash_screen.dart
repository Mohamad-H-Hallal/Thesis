import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_branding.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/widgets/app_logo.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(
      () => ref.read(authControllerProvider.notifier).bootstrap(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(size: 76),
            const SizedBox(height: 12),
            Text(
              AppBranding.shortName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (AppBranding.tagline.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                AppBranding.tagline,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Preparing secure session...'),
          ],
        ),
      ),
    );
  }
}
