import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/auth_failure.dart';
import '../../domain/auth_models.dart';
import '../../domain/auth_repository.dart';

enum AuthStatus { checking, unauthenticated, loading, authenticated }

class AuthState {
  const AuthState({
    required this.status,
    this.session,
    this.error,
    this.errorCode,
  });

  const AuthState.checking() : this(status: AuthStatus.checking);
  const AuthState.unauthenticated([String? error])
    : this(status: AuthStatus.unauthenticated, error: error);
  const AuthState.loading() : this(status: AuthStatus.loading);
  const AuthState.authenticated(AuthSession session)
    : this(status: AuthStatus.authenticated, session: session);

  final AuthStatus status;
  final AuthSession? session;
  final String? error;
  final String? errorCode;

  bool get isAuthenticated =>
      status == AuthStatus.authenticated && session != null;
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repository) : super(const AuthState.checking());

  final AuthRepository _repository;

  Future<void> bootstrap() async {
    state = const AuthState.checking();
    try {
      final session = await _repository.restoreSession();
      state = session == null
          ? const AuthState.unauthenticated()
          : AuthState.authenticated(session);
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
    }
  }

  Future<void> login({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    state = const AuthState.loading();
    try {
      final session = await _repository.login(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      state = AuthState.authenticated(session);
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
    }
  }

  Future<void> reactivateContributorAndLogin({
    required String email,
    required String password,
    required bool rememberMe,
  }) async {
    state = const AuthState.loading();
    try {
      final session = await _repository.reactivateContributorAndLogin(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      state = AuthState.authenticated(session);
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
    }
  }

  Future<String?> signup({
    required String fullName,
    required String email,
    required String password,
    required UserRole role,
    String? phone,
  }) async {
    state = const AuthState.loading();
    try {
      final message = await _repository.signup(
        fullName: fullName,
        email: email,
        password: password,
        role: role,
        phone: phone,
      );
      state = const AuthState.unauthenticated();
      return message;
    } catch (error) {
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
      return null;
    }
  }

  Future<void> logout() async {
    await _repository.logout();
    state = const AuthState(
      status: AuthStatus.unauthenticated,
      errorCode: 'logged_out',
    );
  }

  Future<void> selfDeactivate() async {
    final previousSession = state.session;
    try {
      await _repository.selfDeactivate();
      state = const AuthState.unauthenticated();
    } catch (error) {
      state = AuthState(
        status: previousSession == null
            ? AuthStatus.unauthenticated
            : AuthStatus.authenticated,
        session: previousSession,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
      rethrow;
    }
  }

  Future<PasswordResetRequestResult> requestPasswordReset(String email) {
    return _repository.requestPasswordReset(email);
  }

  Future<PasswordResetOtpVerificationResult> verifyPasswordResetOtp({
    required String email,
    required String otp,
  }) {
    return _repository.verifyPasswordResetOtp(email: email, otp: otp);
  }

  Future<void> resetPassword({
    required String resetToken,
    required String newPassword,
  }) {
    return _repository.resetPassword(
      resetToken: resetToken,
      newPassword: newPassword,
    );
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) {
    return _repository.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
  }

  Future<void> updateProfile({String? fullName, String? phone}) async {
    final session = state.session;
    if (session == null) {
      throw const AuthFailure(
        'Your session may have expired. Please sign in again.',
        code: 'session_missing',
      );
    }

    try {
      final updatedUser = await _repository.updateProfile(
        fullName: fullName,
        phone: phone,
      );
      state = AuthState.authenticated(
        AuthSession(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
          user: updatedUser,
        ),
      );
    } catch (error) {
      state = AuthState(
        status: AuthStatus.authenticated,
        session: session,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
      rethrow;
    }
  }

  String _messageFromError(Object error) {
    if (error is AuthFailure) {
      return error.message;
    }
    return error.toString();
  }

  String? _codeFromError(Object error) {
    if (error is AuthFailure) {
      return error.code;
    }
    return null;
  }
}
