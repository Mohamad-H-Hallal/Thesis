// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

// Best-effort workaround for Chrome autofill diagnostics on Flutter web.
// Flutter's generated <input> elements do not always expose stable id/name
// attributes, so this patch assigns deterministic values for auth forms only.
const Set<String> _supportedInputTypes = <String>{
  'text',
  'email',
  'password',
  'search',
  'tel',
};

void patchAuthInputAttributes({
  required String formId,
  required List<String> fieldKeys,
}) {
  if (fieldKeys.isEmpty) {
    return;
  }

  var attempt = 0;

  void apply() {
    attempt += 1;
    final inputElements = html.document
        .querySelectorAll('input')
        .whereType<html.InputElement>()
        .where(_isVisibleTextInput)
        .toList(growable: false);

    if (inputElements.length < fieldKeys.length && attempt < 12) {
      Future<void>.delayed(const Duration(milliseconds: 100), apply);
      return;
    }

    if (inputElements.isEmpty) {
      return;
    }

    final startIndex = inputElements.length >= fieldKeys.length
        ? inputElements.length - fieldKeys.length
        : 0;
    final targetInputs = inputElements.sublist(startIndex);

    for (var i = 0; i < targetInputs.length && i < fieldKeys.length; i++) {
      final input = targetInputs[i];
      final fieldKey = fieldKeys[i];
      final stableName = '${formId}_$fieldKey';
      input.id = stableName;
      input.name = stableName;
      input.setAttribute('autocomplete', _autocompleteHintFor(fieldKey));
      input.setAttribute('data-auth-form', formId);
      input.setAttribute('data-auth-field', fieldKey);
      if (input.getAttribute('data-enter-blocked') != 'true') {
        input.onKeyDown.listen((event) {
          if (event.key == 'Enter') {
            event.preventDefault();
          }
        });
        input.setAttribute('data-enter-blocked', 'true');
      }
    }
  }

  html.window.requestAnimationFrame((_) => apply());
}

bool _isVisibleTextInput(html.InputElement input) {
  if (!_supportedInputTypes.contains(input.type)) {
    return false;
  }

  if (input.disabled == true) {
    return false;
  }

  final style = input.style;
  if (style.display == 'none' || style.visibility == 'hidden') {
    return false;
  }

  return true;
}

String _autocompleteHintFor(String fieldKey) {
  if (fieldKey.contains('email') || fieldKey.contains('username')) {
    return 'username';
  }
  if (fieldKey.contains('confirm') || fieldKey.contains('new_password')) {
    return 'new-password';
  }
  if (fieldKey.contains('password')) {
    return 'current-password';
  }
  if (fieldKey.contains('name')) {
    return 'name';
  }
  if (fieldKey.contains('phone')) {
    return 'tel';
  }
  return 'on';
}
