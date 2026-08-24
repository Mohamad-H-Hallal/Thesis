import 'package:flutter/material.dart';

/// Owns text controllers for the full lifetime of a dialog route.
///
/// A `showDialog` future completes when the route is popped, before its reverse
/// animation has necessarily removed the dialog widgets. Controllers created by
/// the caller and disposed immediately after `await showDialog(...)` can
/// therefore be disposed while text fields still depend on them. Keeping the
/// controllers in the dialog subtree makes disposal follow actual unmounting.
class AppDialogControllerHost extends StatefulWidget {
  const AppDialogControllerHost({
    required this.builder,
    this.initialValues = const <String>[],
    super.key,
  });

  final List<String> initialValues;
  final Widget Function(
    BuildContext context,
    List<TextEditingController> controllers,
  )
  builder;

  @override
  State<AppDialogControllerHost> createState() =>
      _AppDialogControllerHostState();
}

class _AppDialogControllerHostState extends State<AppDialogControllerHost> {
  late final List<TextEditingController> _controllers = List.unmodifiable(
    widget.initialValues.map((value) => TextEditingController(text: value)),
  );

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controllers);
}
