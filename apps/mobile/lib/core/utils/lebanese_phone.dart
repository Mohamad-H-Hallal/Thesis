class LebanesePhone {
  const LebanesePhone._();

  static final RegExp _digitsOnlyPattern = RegExp(r'\D');
  static final RegExp _localPattern = RegExp(r'^\d{8}$');

  static String digitsOnly(String value) {
    return value.replaceAll(_digitsOnlyPattern, '');
  }

  static String normalize(String value) {
    return digitsOnly(value);
  }

  static bool isValid(String value) {
    final normalized = normalize(value);
    return _localPattern.hasMatch(normalized);
  }

  static String format(String? value) {
    final normalized = normalize(value ?? '');
    if (!_localPattern.hasMatch(normalized)) {
      return (value ?? '').trim();
    }
    return '${normalized.substring(0, 2)} ${normalized.substring(2, 5)} ${normalized.substring(5)}';
  }
}
