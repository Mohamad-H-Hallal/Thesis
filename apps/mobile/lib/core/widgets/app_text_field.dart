import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTextField extends StatelessWidget {
  const AppTextField({
    required this.label,
    required this.controller,
    this.hint,
    this.validator,
    this.keyboardType,
    this.obscureText = false,
    this.suffix,
    this.autofillHints,
    this.textInputAction,
    this.focusNode,
    this.onFieldSubmitted,
    this.inputFormatters,
    this.enabled = true,
    this.autocorrect = false,
    this.enableSuggestions = true,
    this.textCapitalization = TextCapitalization.none,
    this.onChanged,
    super.key,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final bool obscureText;
  final Widget? suffix;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final ValueChanged<String>? onFieldSubmitted;
  final List<TextInputFormatter>? inputFormatters;
  final bool enabled;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextCapitalization textCapitalization;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      obscureText: obscureText,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      focusNode: focusNode,
      onFieldSubmitted: onFieldSubmitted,
      inputFormatters: inputFormatters,
      enabled: enabled,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
      ),
    );
  }
}
