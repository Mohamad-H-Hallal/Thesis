import 'auth_models.dart';

enum ContactVerificationStep { email, phoneFormat, phone, complete }

class ContactVerificationState {
  const ContactVerificationState({
    required this.accountStatus,
    required this.emailVerified,
    required this.phoneVerified,
    required this.phoneFormatValidated,
    required this.phoneAssuranceMode,
    required this.phoneAssuranceLevel,
    required this.phoneOwnershipRequired,
    required this.nextStep,
    required this.maskedEmail,
    required this.maskedPhone,
    this.expiresAt,
    this.resendAfterSeconds = 0,
  });

  final String accountStatus;
  final bool emailVerified;
  final bool phoneVerified;
  final bool phoneFormatValidated;
  final String phoneAssuranceMode;
  final String phoneAssuranceLevel;
  final bool phoneOwnershipRequired;
  final ContactVerificationStep nextStep;
  final String maskedEmail;
  final String maskedPhone;
  final DateTime? expiresAt;
  final int resendAfterSeconds;

  factory ContactVerificationState.fromJson(Map<String, dynamic> json) {
    final rawStep = json['next_step'] as String?;
    return ContactVerificationState(
      accountStatus:
          json['account_status'] as String? ?? 'pending_verification',
      emailVerified: json['email_verified'] == true,
      phoneVerified: json['phone_verified'] == true,
      phoneFormatValidated: json['phone_format_validated'] == true,
      phoneAssuranceMode:
          json['phone_assurance_mode'] as String? ?? 'format_only',
      phoneAssuranceLevel:
          json['phone_assurance_level'] as String? ?? 'unvalidated',
      phoneOwnershipRequired: json['phone_ownership_required'] == true,
      nextStep: switch (rawStep) {
        'phone_format' => ContactVerificationStep.phoneFormat,
        'phone' => ContactVerificationStep.phone,
        'complete' => ContactVerificationStep.complete,
        _ => ContactVerificationStep.email,
      },
      maskedEmail: json['masked_email'] as String? ?? 'your email',
      maskedPhone: json['masked_phone'] as String? ?? 'your mobile number',
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
      resendAfterSeconds: (json['resend_after_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class ContactVerificationResult {
  const ContactVerificationResult({
    required this.message,
    required this.state,
    this.session,
  });

  final String message;
  final ContactVerificationState state;
  final AuthSession? session;
}
