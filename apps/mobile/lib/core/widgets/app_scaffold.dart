import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../constants/design_tokens.dart';
import 'offline_banner.dart';

class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
    this.drawer,
    this.bottomNavigationBar,
    this.showOfflineBanner = true,
    this.showBackButton,
    super.key,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Widget? drawer;
  final Widget? bottomNavigationBar;
  final bool showOfflineBanner;
  final bool? showBackButton;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final router = GoRouter.maybeOf(context);
    final canPop =
        Navigator.of(context).canPop() || (router?.canPop() ?? false);
    final shouldShowBackButton = showBackButton ?? canPop;
    final shouldImplyLeading = shouldShowBackButton || drawer != null;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: shouldImplyLeading,
        leading: shouldShowBackButton
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (router?.canPop() ?? false) {
                    router!.pop();
                    return;
                  }
                  Navigator.of(context).maybePop();
                },
              )
            : null,
        title: Text(title),
        actions: actions,
      ),
      drawer: drawer,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        child: Column(
          children: [
            if (showOfflineBanner) const OfflineBanner(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scheme.surfaceContainerHighest.withValues(
                              alpha: 0.35,
                            ),
                            scheme.surface.withValues(alpha: 0.0),
                          ],
                        ),
                        borderRadius: AppRadii.lg,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: body,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
