import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/widgets/app_scaffold.dart';

void main() {
  Future<void> pumpScaffold(
    WidgetTester tester, {
    required MediaQueryData mediaQuery,
    Widget? bottomNavigationBar,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: mediaQuery,
          child: AppScaffold(
            title: 'Edge to edge',
            showOfflineBanner: false,
            body: ListView(
              children: const [
                SizedBox(height: 24),
                Text('Body content'),
                SizedBox(height: 600),
              ],
            ),
            bottomNavigationBar: bottomNavigationBar,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'app scaffold stays stable with gesture navigation insets and bottom navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpScaffold(
        tester,
        mediaQuery: const MediaQueryData(
          padding: EdgeInsets.only(top: 32, bottom: 24),
        ),
        bottomNavigationBar: NavigationBar(
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'One'),
            NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              label: 'Two',
            ),
          ],
        ),
      );

      expect(find.text('Body content'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'app scaffold stays stable with larger bottom insets and no bottom navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpScaffold(
        tester,
        mediaQuery: const MediaQueryData(
          padding: EdgeInsets.only(top: 32, bottom: 48),
        ),
      );

      await tester.ensureVisible(find.text('Body content'));

      expect(find.text('Body content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
