import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppSystemUiScope extends StatelessWidget {
  const AppSystemUiScope({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkMode = theme.brightness == Brightness.dark;
    final overlayStyle = (darkMode
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark)
        .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          statusBarBrightness: darkMode ? Brightness.dark : Brightness.light,
          statusBarIconBrightness: darkMode ? Brightness.light : Brightness.dark,
          systemNavigationBarIconBrightness: darkMode
              ? Brightness.light
              : Brightness.dark,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: ColoredBox(
        color: theme.colorScheme.surface,
        child: child,
      ),
    );
  }
}
