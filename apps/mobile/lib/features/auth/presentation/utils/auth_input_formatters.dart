import 'package:flutter/services.dart';

import '../../../../core/utils/lebanese_phone.dart';

class NoLeadingSpaceFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) {
      return newValue;
    }

    final trimmedLeading = text.replaceFirst(RegExp(r'^\s+'), '');
    if (trimmedLeading == text) {
      return newValue;
    }

    final delta = text.length - trimmedLeading.length;
    final selectionOffset = (newValue.selection.baseOffset - delta).clamp(
      0,
      trimmedLeading.length,
    );

    return TextEditingValue(
      text: trimmedLeading,
      selection: TextSelection.collapsed(offset: selectionOffset),
      composing: TextRange.empty,
    );
  }
}

class LebanesePhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = LebanesePhone.normalize(newValue.text);
    final truncated = normalized.length > 8
        ? normalized.substring(0, 8)
        : normalized;
    final formatted = LebanesePhone.format(truncated);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
      composing: TextRange.empty,
    );
  }
}
