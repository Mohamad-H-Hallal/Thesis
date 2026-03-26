import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/auth_failure.dart';
import '../../domain/auth_models.dart';
import '../../domain/auth_repository.dart';

enum AuthStatus { checking, unauthenticated, loading, authenticated }

class AuthState {
  const AuthState({required this.status, this.session, this.error});

  const AuthState.checking() : this(status: AuthStatus.checking);
  const AuthState.unauthenticated([String? error])
    : this(status: AuthStatus.unauthenticated, error: error);
  const AuthState.loading() : this(status: AuthStatus.loading);
  const AuthState.authenticated(AuthSession session)
    : this(status: AuthStatus.authenticated, session: session);

  final AuthStatus status;
  final AuthSession? session;
  final String? error;

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
      state = AuthState.unauthenticated(_messageFromError(error));
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
      state = AuthState.unauthenticated(_messageFromError(error));
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
      state = AuthState.unauthenticated(_messageFromError(error));
      return null;
    }
  }

  Future<void> logout() async {
    await _repository.logout();
    state = const AuthState.unauthenticated();
  }

  Future<void> selfDeactivate() async {
    state = const AuthState.loading();
    try {
      await _repository.selfDeactivate();
      state = const AuthState.unauthenticated();
    } catch (error) {
      state = AuthState.unauthenticated(_messageFromError(error));
      rethrow;
    }
  }

  Future<PasswordResetRequestResult> requestPasswordReset(String email) {
    return _repository.requestPasswordReset(email);
  }

  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) {
    return _repository.resetPassword(token: token, newPassword: newPassword);
  }

  String _messageFromError(Object error) {
    if (error is AuthFailure) {
      return error.message;
    }
    return error.toString();
  }
}
