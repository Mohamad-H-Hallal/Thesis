import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/widgets/terraleb_logo.dart';

void main() {
  Widget buildLogo({
    required ThemeMode themeMode,
    Brightness? brightness,
    double width = 240,
    double height = 96,
  }) {
    return MaterialApp(
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: themeMode,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Center(
          child: TerraLebLogo(
            width: width,
            height: height,
            brightness: brightness,
          ),
        ),
      ),
    );
  }

  String displayedAsset(WidgetTester tester) {
    final image = tester.widget<Image>(find.byType(Image));
    return (image.image as AssetImage).assetName;
  }

  testWidgets('uses the transparent light logo with accessible semantics', (
    tester,
  ) async {
    await tester.pumpWidget(buildLogo(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    expect(displayedAsset(tester), TerraLebLogo.lightAsset);
    expect(find.bySemanticsLabel('TerraLeb logo'), findsOneWidget);
    expect(tester.getSize(find.byType(Image)), const Size(228, 84));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
    expect(
      find.descendant(
        of: find.byType(TerraLebLogo),
        matching: find.byType(ColoredBox),
      ),
      findsNothing,
    );
  });

  testWidgets('switches immediately to the dark logo when the theme changes', (
    tester,
  ) async {
    await tester.pumpWidget(buildLogo(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    expect(displayedAsset(tester), TerraLebLogo.lightAsset);

    await tester.pumpWidget(buildLogo(themeMode: ThemeMode.dark));
    await tester.pump();

    expect(displayedAsset(tester), TerraLebLogo.darkAsset);
  });

  testWidgets('explicit brightness overrides the inherited theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildLogo(themeMode: ThemeMode.dark, brightness: Brightness.light),
    );
    await tester.pumpAndSettle();

    expect(displayedAsset(tester), TerraLebLogo.lightAsset);
  });
}
