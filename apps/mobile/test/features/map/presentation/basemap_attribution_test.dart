import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/map/domain/lebanon_map.dart';
import 'package:lebanese_gis_mobile/features/map/presentation/widgets/basemap_attribution.dart';

void main() {
  testWidgets('street and satellite maps render their required attribution', (
    tester,
  ) async {
    for (final style in LebanonBasemapStyle.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FlutterMap(
              options: MapOptions(
                initialCenter: LebanonMapConfig.center,
                initialZoom: LebanonMapConfig.quickInitialZoom,
              ),
              children: [BasemapAttribution(style: style)],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text(LebanonMapConfig.compactAttributionText(style)),
        findsOneWidget,
      );
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        LebanonMapConfig.attributionText(style),
      );
    }
  });

  testWidgets('attribution bottom inset reserves space for map controls', (
    tester,
  ) async {
    Future<double> pumpWithInset(double bottomInset) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 500,
              child: BasemapAttribution(
                style: LebanonBasemapStyle.street,
                bottomInset: bottomInset,
              ),
            ),
          ),
        ),
      );
      return tester
          .getRect(
            find.text(
              LebanonMapConfig.compactAttributionText(
                LebanonBasemapStyle.street,
              ),
            ),
          )
          .bottom;
    }

    final defaultBottom = await pumpWithInset(0);
    final reservedBottom = await pumpWithInset(80);
    expect(defaultBottom - reservedBottom, closeTo(80, 0.1));
  });
}
