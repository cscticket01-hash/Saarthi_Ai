import 'dart:async';

import 'windows_local_settings.dart';

class FirebaseAuthException implements Exception {
  FirebaseAuthException({
    required this.code,
    this.message,
  });

  final String code;
  final String? message;

  @override
  String toString() =>
      message == null ? code : '$code: $message';
}

class AuthCredential {
  const AuthCredential({
    required this.email,
    required this.password,
  });

  final String email;
  final String password;
}

class EmailAuthProvider {
  EmailAuthProvider._();

  static AuthCredential credential({
    required String email,
    required String password,
  }) {
    return AuthCredential(
      email: email,
      password: password,
    );
  }
}

class User {
  User({
    required this.email,
    required this.displayName,
  });

  final String? email;
  final String? displayName;

  Future<UserCredential> reauthenticateWithCredential(
    AuthCredential credential,
  ) async {
    if (!WindowsLocalSecurity.configured) {
      throw FirebaseAuthException(
        code: 'local-settings-lock-not-configured',
        message: 'Local Settings Lock configure nahi hai.',
      );
    }

    if (!WindowsLocalSecurity.verify(
      adminId: credential.email,
      password: credential.password,
    )) {
      throw FirebaseAuthException(
        code: 'wrong-password',
        message: 'Local Admin ID ya Settings Password galat hai.',
      );
    }

    return UserCredential(user: this);
  }
}

class UserCredential {
  const UserCredential({
    required this.user,
  });

  final User? user;
}

class FirebaseAuth {
  FirebaseAuth._();

  static final FirebaseAuth instance = FirebaseAuth._();

  User? _currentUser;

  User? get currentUser => _currentUser;

  Future<void> bootstrapLocalUser() async {
    await WindowsLocalSecurity.initialize();

    if (WindowsLocalSecurity.configured) {
      _currentUser = User(
        email: WindowsLocalSecurity.adminId,
        displayName: WindowsLocalSecurity.adminId,
      );
    } else {
      _currentUser = null;
    }
  }

  Future<void> refreshLocalUser() async {
    await bootstrapLocalUser();
  }

  Future<UserCredential> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    if (!WindowsLocalSecurity.configured) {
      throw FirebaseAuthException(
        code: 'local-settings-lock-not-configured',
        message: 'Pehle Local Settings Lock configure karein.',
      );
    }

    if (!WindowsLocalSecurity.verify(
      adminId: email,
      password: password,
    )) {
      throw FirebaseAuthException(
        code: 'invalid-credential',
        message: 'Local Admin ID ya Settings Password galat hai.',
      );
    }

    _currentUser = User(
      email: WindowsLocalSecurity.adminId,
      displayName: WindowsLocalSecurity.adminId,
    );

    return UserCredential(user: _currentUser);
  }

  Future<void> signOut() async {
    // Session logout only. Local ID/password secure storage me rehte hain.
    _currentUser = null;
  }

  Stream<User?> authStateChanges() async* {
    yield _currentUser;
  }
}
