import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/widgets/app_dialog_actions.dart';

void main() {
  for (final size in <Size>[const Size(800, 900)]) {
    testWidgets(
      'dialog actions use an equal-width row at ${size.width.toInt()}px',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AlertDialog(
                  title: const Text('Confirm'),
                  content: const Text('Continue?'),
                  actions: [
                    AppDialogActions(
                      cancel: TextButton(
                        onPressed: () {},
                        child: const Text('Cancel'),
                      ),
                      confirm: FilledButton(
                        onPressed: () {},
                        child: const Text('Confirm'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        final cancelRect = tester.getRect(
          find.widgetWithText(TextButton, 'Cancel'),
        );
        final confirmRect = tester.getRect(
          find.widgetWithText(FilledButton, 'Confirm'),
        );
        expect(cancelRect.width, closeTo(confirmRect.width, 0.1));
        expect(cancelRect.top, closeTo(confirmRect.top, 0.1));
        expect(confirmRect.left, greaterThan(cancelRect.right));
        final cancelLabelRect = tester.getRect(find.text('Cancel'));
        expect(cancelLabelRect.center.dx, closeTo(cancelRect.center.dx, 0.1));
        expect(cancelLabelRect.center.dy, closeTo(cancelRect.center.dy, 0.1));
        final cancelContext = tester.element(
          find.widgetWithText(TextButton, 'Cancel'),
        );
        final cancelStyle = TextButtonTheme.of(cancelContext).style;
        expect(cancelStyle?.side?.resolve(<WidgetState>{}), isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('concise cancellation labels stay in an equal row on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(size: Size(320, 640)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: const Text('Cancel correction request?'),
              actions: [
                AppDialogActions(
                  cancel: TextButton(
                    onPressed: () {},
                    child: const AppDialogActionLabel('Keep'),
                  ),
                  confirm: FilledButton(
                    onPressed: () {},
                    child: const AppDialogActionLabel('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final keepButton = tester.getRect(find.widgetWithText(TextButton, 'Keep'));
    final cancelButton = tester.getRect(
      find.widgetWithText(FilledButton, 'Cancel'),
    );
    final cancelLabel = tester.getRect(find.text('Cancel'));
    expect(cancelButton.top, closeTo(keepButton.top, 0.1));
    expect(cancelButton.width, closeTo(keepButton.width, 0.1));
    expect(cancelButton.left, greaterThan(keepButton.right));
    expect(cancelButton.contains(cancelLabel.center), isTrue);
    expect(cancelLabel.center.dx, closeTo(cancelButton.center.dx, 0.1));
    expect(cancelLabel.center.dy, closeTo(cancelButton.center.dy, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel request stays centered in a narrow equal-width row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(411, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(size: Size(411, 700)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: const Text('Cancel correction request?'),
              actions: [
                AppDialogActions(
                  cancel: TextButton(
                    onPressed: () {},
                    child: const AppDialogActionLabel('Keep'),
                  ),
                  confirm: FilledButton(
                    onPressed: () {},
                    child: const AppDialogActionLabel('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final keepButton = tester.getRect(find.widgetWithText(TextButton, 'Keep'));
    final cancelButton = tester.getRect(
      find.widgetWithText(FilledButton, 'Cancel'),
    );
    final cancelLabel = tester.getRect(find.text('Cancel'));
    expect(cancelButton.top, closeTo(keepButton.top, 0.1));
    expect(cancelButton.width, closeTo(keepButton.width, 0.1));
    expect(cancelButton.left, greaterThan(keepButton.right));
    expect(
      cancelLabel.height,
      lessThan(24),
      reason: 'button=$cancelButton label=$cancelLabel',
    );
    expect(cancelLabel.left, greaterThanOrEqualTo(cancelButton.left));
    expect(cancelLabel.right, lessThanOrEqualTo(cancelButton.right));
    expect(cancelLabel.center.dx, closeTo(cancelButton.center.dx, 0.1));
    expect(cancelLabel.center.dy, closeTo(cancelButton.center.dy, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dialog actions stay in an equal row at large text scales', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: const Text('Confirm'),
              actions: [
                AppDialogActions(
                  cancel: TextButton(
                    onPressed: () {},
                    child: const Text('Cancel'),
                  ),
                  confirm: FilledButton(
                    onPressed: () {},
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final cancelRect = tester.getRect(
      find.widgetWithText(TextButton, 'Cancel'),
    );
    final confirmRect = tester.getRect(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(cancelRect.width, closeTo(confirmRect.width, 0.1));
    expect(confirmRect.top, closeTo(cancelRect.top, 0.1));
    expect(confirmRect.left, greaterThan(cancelRect.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('single dialog action fills the available action row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AlertDialog(
              title: const Text('Notice'),
              actions: [
                AppDialogActions.single(
                  confirm: FilledButton(
                    onPressed: () {},
                    child: const Text('OK'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final dialogRect = tester.getRect(find.byType(AlertDialog));
    final actionsRect = tester.getRect(find.byType(AppDialogActions));
    final buttonRect = tester.getRect(find.widgetWithText(FilledButton, 'OK'));
    expect(buttonRect.center.dx, closeTo(dialogRect.center.dx, 0.1));
    expect(buttonRect.width, closeTo(actionsRect.width, 0.1));
    expect(buttonRect.width, lessThan(dialogRect.width));
    expect(tester.takeException(), isNull);
  });
}
