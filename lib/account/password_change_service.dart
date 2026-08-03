import 'package:matrix/matrix.dart';

const minimumAccountPasswordLength = 8;

String? validatePasswordChange({
  required String currentPassword,
  required String newPassword,
  required String confirmation,
}) {
  if (currentPassword.isEmpty) {
    return 'Enter your current password.';
  }
  if (newPassword.isEmpty) {
    return 'Enter a new password.';
  }
  if (newPassword.length < minimumAccountPasswordLength) {
    return 'Use at least $minimumAccountPasswordLength characters.';
  }
  if (newPassword != confirmation) {
    return 'The new passwords do not match.';
  }
  if (newPassword == currentPassword) {
    return 'Choose a password different from your current password.';
  }
  return null;
}

Future<void> changeOwnPassword({
  required Client client,
  required String currentPassword,
  required String newPassword,
}) {
  return client.changePassword(
    newPassword,
    oldPassword: currentPassword,
    // A password change should not unexpectedly disconnect the user's other
    // Patrick Messenger devices. Synapse may still soft-log-out a device if
    // its own security policy requires it.
    logoutDevices: false,
  );
}

String passwordChangeErrorMessage(Object error) {
  if (error is MatrixException) {
    if (error.errcode == 'M_FORBIDDEN' || error.errcode == 'M_UNAUTHORIZED') {
      return 'The current password is incorrect.';
    }
    if (error.errcode == 'M_WEAK_PASSWORD') {
      return 'The homeserver rejected that password as too weak.';
    }
    if (error.errorMessage.isNotEmpty &&
        error.errorMessage != 'Unknown error') {
      return error.errorMessage;
    }
  }
  return 'The password could not be changed. Check your connection and try again.';
}
