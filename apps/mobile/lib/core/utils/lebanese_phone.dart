import 'package:phone_numbers_parser/phone_numbers_parser.dart';

class LebanesePhone {
  const LebanesePhone._();

  static const _arabicDigits = <String, String>{
    '٠': '0',
    '١': '1',
    '٢': '2',
    '٣': '3',
    '٤': '4',
    '٥': '5',
    '٦': '6',
    '٧': '7',
    '٨': '8',
    '٩': '9',
    '۰': '0',
    '۱': '1',
    '۲': '2',
    '۳': '3',
    '۴': '4',
    '۵': '5',
    '۶': '6',
    '۷': '7',
    '۸': '8',
    '۹': '9',
  };

  static String toAsciiDigits(String value) {
    var result = value;
    for (final entry in _arabicDigits.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  static String digitsOnly(String value) =>
      toAsciiDigits(value).replaceAll(RegExp(r'[^0-9]'), '');

  static PhoneNumber? parse(String value) {
    final input = toAsciiDigits(value).trim();
    if (input.isEmpty) return null;
    try {
      final parsed = PhoneNumber.parse(input, callerCountry: IsoCode.LB);
      return parsed.isoCode == IsoCode.LB ? parsed : null;
    } on PhoneNumberException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static bool isValid(String value) {
    final parsed = parse(value);
    return parsed != null && parsed.isValid(type: PhoneNumberType.mobile);
  }

  static String normalize(String value) {
    final parsed = parse(value);
    if (parsed != null && parsed.isValid(type: PhoneNumberType.mobile)) {
      return parsed.international;
    }
    return toAsciiDigits(value).trim();
  }

  static String localInputDigits(String value) {
    var digits = digitsOnly(value);
    if (digits.startsWith('00961')) {
      digits = digits.substring(5);
    }
    if (digits.startsWith('961')) {
      digits = digits.substring(3);
    }
    if (digits.startsWith('3') && digits.length <= 7) {
      digits = '0$digits';
    }
    return digits.length > 8 ? digits.substring(0, 8) : digits;
  }

  static String formatPartial(String value) {
    final digits = localInputDigits(value);
    if (digits.length <= 2) {
      return digits;
    }
    if (digits.length <= 5) {
      return '${digits.substring(0, 2)} ${digits.substring(2)}';
    }
    return '${digits.substring(0, 2)} ${digits.substring(2, 5)} ${digits.substring(5)}';
  }

  static String format(String? value) {
    final input = value?.trim() ?? '';
    if (input.isEmpty) return '';
    final parsed = parse(input);
    if (parsed != null && parsed.isValid(type: PhoneNumberType.mobile)) {
      return '+961 ${formatPartial(parsed.nsn)}';
    }
    return formatPartial(input);
  }

  static String mask(String? value) {
    final parsed = parse(value ?? '');
    if (parsed == null) return '+961 ** *** ***';
    return '+961 ${parsed.nsn.substring(0, 2)} *** ***';
  }
}
