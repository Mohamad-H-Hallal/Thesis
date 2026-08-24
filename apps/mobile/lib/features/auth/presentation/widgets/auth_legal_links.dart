import 'package:flutter/material.dart';

import '../../../../core/constants/design_tokens.dart';

typedef OpenLegalDocument = void Function(String slug);

class AuthLegalFooter extends StatelessWidget {
  const AuthLegalFooter({required this.onOpenDocument, super.key});

  final OpenLegalDocument onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return Semantics(
      label: 'Legal information',
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 3,
          runSpacing: AppSpacing.xxs,
          children: [
            Text('Read our', style: textStyle, textAlign: TextAlign.center),
            _InlineLegalLink(
              label: 'Privacy Notice',
              onTap: () => onOpenDocument('privacy'),
              textStyle: textStyle,
            ),
            Text('and', style: textStyle, textAlign: TextAlign.center),
            _InlineLegalLink(
              label: 'Terms of Use',
              onTap: () => onOpenDocument('terms'),
              textStyle: textStyle,
            ),
          ],
        ),
      ),
    );
  }
}

class SignupPolicyAcceptance extends StatelessWidget {
  const SignupPolicyAcceptance({
    required this.value,
    required this.onChanged,
    required this.onOpenDocument,
    this.hasError = false,
    super.key,
  });

  final bool value;
  final ValueChanged<bool?>? onChanged;
  final OpenLegalDocument onOpenDocument;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bodyStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(height: 1.4);
    return Semantics(
      container: true,
      label:
          'Required legal agreement. Agree to the Terms of Use and Acceptable Use Policy, and acknowledge reading the Privacy Notice.',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
        decoration: hasError
            ? BoxDecoration(
                color: colors.errorContainer.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(10),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Checkbox(
                  key: const ValueKey('signup-policy-acceptance'),
                  value: value,
                  onChanged: onChanged,
                  visualDensity: VisualDensity.standard,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xxs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 5, right: AppSpacing.xxs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 3,
                      runSpacing: 1,
                      children: [
                        Text('I agree to the', style: bodyStyle),
                        _InlineLegalLink(
                          label: 'Terms of Use',
                          onTap: () => onOpenDocument('terms'),
                          textStyle: bodyStyle,
                        ),
                        Text('and', style: bodyStyle),
                        _InlineLegalLink(
                          label: 'Acceptable Use Policy',
                          onTap: () => onOpenDocument('acceptable-use'),
                          textStyle: bodyStyle,
                        ),
                        Text('and have read the', style: bodyStyle),
                        _InlineLegalLink(
                          label: 'Privacy Notice',
                          onTap: () => onOpenDocument('privacy'),
                          textStyle: bodyStyle,
                        ),
                      ],
                    ),
                    if (hasError) ...[
                      const SizedBox(height: AppSpacing.xxs),
                      Text(
                        'Select the checkbox before continuing.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineLegalLink extends StatelessWidget {
  const _InlineLegalLink({
    required this.label,
    required this.onTap,
    required this.textStyle,
  });

  final String label;
  final VoidCallback onTap;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            label,
            style: textStyle?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
              decorationColor: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
