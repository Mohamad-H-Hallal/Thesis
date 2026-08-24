import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lebanese_gis_mobile/features/legal/domain/legal_models.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/legal_providers.dart';
import 'package:lebanese_gis_mobile/features/legal/presentation/screens/legal_acceptance_screen.dart';

LegalDocument _document(String type, String slug, String title) =>
    LegalDocument(
      type: type,
      slug: slug,
      locale: 'en',
      version: '2.0.0',
      title: title,
      status: 'approved',
      summary: 'Material update',
      sections: const <LegalSection>[],
      contentSha256: List<String>.filled(64, 'a').join(),
      counselApproved: true,
    );

void main() {
  testWidgets(
    'renewed Terms acceptance starts unchecked and keeps Privacy separate',
    (tester) async {
      final status = LegalAcceptanceStatus(
        required: true,
        missingDocuments: <LegalDocument>[
          _document('terms', 'terms', 'Terms of Use'),
          _document(
            'acceptable_use',
            'acceptable-use',
            'Acceptable Use Policy',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            legalAcceptanceStatusProvider.overrideWith((ref) async => status),
          ],
          child: const MaterialApp(home: LegalAcceptanceScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final checkbox = tester.widget<CheckboxListTile>(
        find.byKey(const Key('renewed-legal-acceptance')),
      );
      expect(checkbox.value, isFalse);
      expect(find.text('Privacy Notice'), findsOneWidget);
      expect(find.text('Notice only, not bundled consent'), findsOneWidget);
      final acceptButton = tester.widget<FilledButton>(
        find.byKey(const Key('accept-renewed-legal-documents')),
      );
      expect(acceptButton.onPressed, isNull);
    },
  );
}
