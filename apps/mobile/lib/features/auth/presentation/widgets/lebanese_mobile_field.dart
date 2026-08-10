import 'package:flutter/material.dart';

import '../../../../core/widgets/app_text_field.dart';
import '../utils/auth_form_validators.dart';
import '../utils/auth_input_formatters.dart';

class LebaneseMobileField extends StatelessWidget {
  const LebaneseMobileField({
    required this.controller,
    this.focusNode,
    this.textInputAction,
    this.onFieldSubmitted,
    this.onChanged,
    this.validator,
    this.label = 'Mobile number',
    this.hint = '70 123 456',
    this.semanticLabel =
        'Lebanese mobile number, country code plus nine six one',
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;
  final String label;
  final String hint;
  final String semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      textField: true,
      label: semanticLabel,
      child: AppTextField(
        label: label,
        hint: hint,
        controller: controller,
        keyboardType: TextInputType.phone,
        textInputAction: textInputAction,
        focusNode: focusNode,
        onFieldSubmitted: onFieldSubmitted,
        inputFormatters: <LebanesePhoneFormatter>[LebanesePhoneFormatter()],
        autofillHints: const <String>[AutofillHints.telephoneNumber],
        prefix: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Center(widthFactor: 1, child: Text('+961')),
        ),
        onChanged: onChanged,
        validator: validator ?? AuthFormValidators.phoneRequired,
        enabled: enabled,
      ),
    );
  }
}
