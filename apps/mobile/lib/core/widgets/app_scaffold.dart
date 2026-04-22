import 'dart:math' as math;

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
    final mediaPadding = MediaQuery.paddingOf(context);
    final canPop =
        Navigator.of(context).canPop() || (router?.canPop() ?? false);
    final shouldShowBackButton = showBackButton ?? canPop;
    final shouldImplyLeading = shouldShowBackButton || drawer != null;
    return Scaffold(
      backgroundColor: scheme.surface,
      extendBody: bottomNavigationBar != null,
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compactWidth = constraints.maxWidth < 600;
          final compactHeight = constraints.maxHeight < 700;
          final outerHorizontalPadding = constraints.maxWidth >= 1200
              ? AppSpacing.lg
              : constraints.maxWidth >= 720
              ? AppSpacing.md
              : AppSpacing.sm;
          final outerVerticalPadding = compactHeight
              ? AppSpacing.xs
              : compactWidth
              ? AppSpacing.sm
              : AppSpacing.md;
          final innerPadding = compactWidth ? AppSpacing.xs : AppSpacing.sm;
          final leftInset = math.max(
            mediaPadding.left,
            outerHorizontalPadding,
          );
          final rightInset = math.max(
            mediaPadding.right,
            outerHorizontalPadding,
          );
          final bottomInset = outerVerticalPadding +
              (bottomNavigationBar == null ? mediaPadding.bottom : 0);
          final borderRadius = compactWidth ? AppRadii.md : AppRadii.lg;

          return Column(
            children: [
              if (showOfflineBanner) const OfflineBanner(),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    leftInset,
                    outerVerticalPadding,
                    rightInset,
                    bottomInset,
                  ),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1280),
                      child: ClipRRect(
                        borderRadius: borderRadius,
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
    );
  }
}
