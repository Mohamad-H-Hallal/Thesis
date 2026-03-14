class AuthFormValidators {
  const AuthFormValidators._();

  static final RegExp _emailPattern = RegExp(
    r"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$",
    caseSensitive: false,
  );
  static final RegExp _uppercasePattern = RegExp(r'[A-Z]');
  static final RegExp _lowercasePattern = RegExp(r'[a-z]');
  static final RegExp _numberPattern = RegExp(r'\d');
  static final RegExp _symbolPattern = RegExp(
    r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\\/~`]',
  );
  static final RegExp _phonePattern = RegExp(r'^\d{8,15}$');

  static String normalize(String value) {
    return value.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String? requiredField(
    String? value, {
    required String fieldLabel,
    int minLength = 1,
  }) {
    final normalized = normalize(value ?? '');
    if (normalized.isEmpty) {
      return '$fieldLabel is required';
    }
    if (normalized.length < minLength) {
      return '$fieldLabel must be at least $minLength characters';
    }
    return null;
  }

  static String? email(String? value) {
    final normalized = normalize(value ?? '');
    if (normalized.isEmpty) {
      return 'Email is required';
    }
    if (!_emailPattern.hasMatch(normalized)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  static String? password(String? value) {
    final input = value ?? '';
    if (input.isEmpty) {
      return 'Password is required';
    }
    if (input.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (!_uppercasePattern.hasMatch(input)) {
      return 'Password must include at least one uppercase letter';
    }
    if (!_lowercasePattern.hasMatch(input)) {
      return 'Password must include at least one lowercase letter';
    }
    if (!_numberPattern.hasMatch(input)) {
      return 'Password must include at least one number';
    }
    if (!_symbolPattern.hasMatch(input)) {
      return 'Password must include at least one symbol';
    }
    return null;
  }

  static String? loginPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return 'Password is required';
    }
    return null;
  }

  static String? confirmPassword({
    required String? value,
    required String password,
  }) {
    if ((value ?? '').isEmpty) {
      return 'Confirm password is required';
    }
    if (value != password) {
      return 'Passwords do not match';
    }
    return null;
  }

  static String? phoneOptional(String? value) {
    final normalized = normalize(value ?? '');
    if (normalized.isEmpty) {
      return null;
    }
    if (!_phonePattern.hasMatch(normalized)) {
      return 'Phone must contain 8 to 15 digits';
    }
    return null;
  }

  static String? phoneRequired(String? value) {
    final normalized = normalize(value ?? '');
    if (normalized.isEmpty) {
      return 'Phone is required';
    }
    if (!_phonePattern.hasMatch(normalized)) {
      return 'Phone must contain 8 to 15 digits';
    }
    return null;
  }
}
