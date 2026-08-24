import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/core/providers/providers.dart';
import 'package:lebanese_gis_mobile/core/realtime/realtime_edit_guard.dart';
import 'package:lebanese_gis_mobile/features/admin/domain/admin_models.dart';
import 'package:lebanese_gis_mobile/features/admin/presentation/screens/category_form_screen.dart';

void main() {
  testWidgets(
    'editing category unregisters safely when the screen is disposed',
    (tester) async {
      final registry = RealtimeEditGuardRegistry();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            realtimeEditGuardRegistryProvider.overrideWithValue(registry),
            projectCategoriesProvider.overrideWith(
              (ref) async => const [
                ProjectCategorySummary(id: 'category-1', name: 'Environment'),
              ],
            ),
          ],
          child: const MaterialApp(
            home: CategoryFormScreen(categoryId: 'category-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(registry.isEditing('category', 'category-1'), isTrue);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      expect(registry.isEditing('category', 'category-1'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
