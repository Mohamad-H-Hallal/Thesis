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
  Future<void>? _logoutFuture;

  Future<void> bootstrap() async {
    state = const AuthState.checking();
    try {
      final session = await _repository.restoreSession();
      if (!mounted) {
        return;
      }
      state = session == null
          ? const AuthState.unauthenticated()
          : AuthState.authenticated(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
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
    await _waitForPendingLogout();
    if (!mounted) {
      return;
    }
    state = const AuthState.loading();
    try {
      final session = await _repository.login(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      if (!mounted) {
        return;
      }
      state = AuthState.authenticated(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
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
    await _waitForPendingLogout();
    if (!mounted) {
      return;
    }
    state = const AuthState.loading();
    try {
      final session = await _repository.reactivateContributorAndLogin(
        email: email,
        password: password,
        rememberMe: rememberMe,
      );
      if (!mounted) {
        return;
      }
      state = AuthState.authenticated(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
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
      if (!mounted) {
        return message;
      }
      state = const AuthState.unauthenticated();
      return message;
    } catch (error) {
      if (!mounted) {
        return null;
      }
      state = AuthState(
        status: AuthStatus.unauthenticated,
        error: _messageFromError(error),
        errorCode: _codeFromError(error),
      );
      return null;
    }
  }

  Future<void> logout() async {
    if (!mounted) {
      return;
    }
    state = const AuthState(
      status: AuthStatus.unauthenticated,
      errorCode: 'logged_out',
    );
    await _finishLogout();
  }

  void completeContactVerification(AuthSession session) {
    if (!mounted) return;
    state = AuthState.authenticated(session);
  }

  Future<void> forceLogout({String? message, String? code}) async {
    if (!mounted) {
      return;
    }
    state = AuthState(
      status: AuthStatus.unauthenticated,
      error: message,
      errorCode: code ?? 'logged_out',
    );
    await _finishLogout();
  }

  Future<void> _waitForPendingLogout() async {
    final pendingLogout = _logoutFuture;
    if (pendingLogout != null) {
      await pendingLogout;
    }
  }

  Future<void> _finishLogout() {
    final pendingLogout = _logoutFuture;
    if (pendingLogout != null) {
      return pendingLogout;
    }
    final future = _repository.logout().catchError((_) {
      // Local unauthenticated state is authoritative even when the best-effort
      // server logout request fails.
    });
    _logoutFuture = future;
    return future.whenComplete(() {
      if (identical(_logoutFuture, future)) {
        _logoutFuture = null;
      }
    });
  }

  Future<void> selfDeactivate() async {
    final previousSession = state.session;
    try {
      await _repository.selfDeactivate();
      if (!mounted) {
        return;
      }
      state = const AuthState(
        status: AuthStatus.unauthenticated,
        errorCode: 'self_deactivated',
      );
    } catch (error) {
      if (!mounted) {
        rethrow;
      }
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
  }) async {
    await _repository.changePassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
    );
    final currentSession = state.session;
    if (currentSession == null || _repository is! AuthTokenRotationSource) {
      return;
    }
    final rotated = (_repository as AuthTokenRotationSource)
        .takeRotatedAuthTokens();
    if (rotated == null) {
      return;
    }
    state = AuthState.authenticated(
      AuthSession(
        accessToken: rotated.accessToken,
        refreshToken: rotated.refreshToken,
        user: currentSession.user,
      ),
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
      if (!mounted) {
        return;
      }
      state = AuthState.authenticated(
        AuthSession(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
          user: updatedUser,
        ),
      );
    } catch (error) {
      if (!mounted) {
        rethrow;
      }
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
