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
    this.onBack,
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
  final VoidCallback? onBack;

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
                  if (onBack != null) {
                    onBack!();
                    return;
                  }
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final outerHorizontalPadding = constraints.maxWidth < 420
                ? AppSpacing.sm
                : AppSpacing.md;
            final outerVerticalPadding = constraints.maxHeight < 720
                ? AppSpacing.sm
                : AppSpacing.md;
            final innerPadding = constraints.maxWidth < 420
                ? AppSpacing.xs
                : AppSpacing.sm;

            return Column(
              children: [
                if (showOfflineBanner) const OfflineBanner(),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: outerHorizontalPadding,
                      vertical: outerVerticalPadding,
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1280),
                        child: ClipRRect(
                          borderRadius: AppRadii.lg,
                          child: ColoredBox(
                            color: scheme.surface,
                            child: Padding(
                              padding: EdgeInsets.all(innerPadding),
                              child: body,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
