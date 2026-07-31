import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:get/get.dart';

import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import '../../data/models/user_profile.dart';
import 'firestore_service.dart';

class AuthService extends GetxService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirestoreService _firestoreService = FirestoreService();

  StreamSubscription<UserProfile?>? _profileSubscription;

  User? get firebaseUser => _auth.currentUser;
  String? get uid => firebaseUser?.uid;

  final Rxn<UserProfile> _userProfile = Rxn<UserProfile>();

  UserProfile? get myProfile => _userProfile.value;

  Stream<UserProfile?> get stream => _userProfile.stream;

  bool get hasUser => _userProfile.value != null;

  /// Waits for Firebase Auth to restore persisted session before deciding
  /// whether a new anonymous sign-in is required.
  Future<void> signInAnonymousIfNeeded() async {
    final User? restoredUser = await _auth.authStateChanges().first;
    final String? restoredUid = restoredUser?.uid;

    testPrintLS(
      DiagnosticLog.flow(
        'AuthService',
        'auth_state_ready',
        data: {
          'hasUser': restoredUser != null,
          'uid': restoredUid,
        },
      ),
    );

    if (_auth.currentUser != null) {
      return;
    }

    await _auth.signInAnonymously();

    testPrintLS(
      DiagnosticLog.flow(
        'AuthService',
        'anonymous_sign_in_created',
        data: {'uid': _auth.currentUser?.uid},
      ),
    );
  }

  Future<void> logout() async {
    await _auth.signOut();
    clear();
  }

  void init(UserProfile profile) {
    setUserProfile(profile);
  }

  void _startWatchingMyProfile() {
    _profileSubscription?.cancel();
    _profileSubscription = _firestoreService.watchMyProfile().listen(
      (UserProfile? profile) {
        if (profile == null) return;
        testPrintLS(
          DiagnosticLog.flow(
            'AuthService',
            'my_profile_updated_from_firestore',
            data: {'tribeId': profile.tribeId, 'uid': profile.uid},
          ),
        );
        _userProfile.value = profile;
      },
      onError: (Object error) {
        testPrintLS(
          DiagnosticLog.err(
            'AuthService',
            'watch_my_profile_failed',
            data: {'error': error.toString()},
          ),
        );
      },
    );
  }

  void setUserProfile(UserProfile profile) {
    _userProfile.value = profile;
    _startWatchingMyProfile();
  }

  void updateMyProfile(UserProfile newValue) {
    final UserProfile? currentProfile = _userProfile.value;
    if (currentProfile == null) return;

    final data = currentProfile.updatedData(newValue);
    _userProfile.value = newValue;
    if (data.isNotEmpty) {
      _firestoreService.updateMyProfile(data);
    }
  }

  Future<String?> getFirebaseIdToken() async {
    final User? user = firebaseUser;
    if (user == null) return null;

    final idToken = await user.getIdToken();
    return idToken;
  }

  // void updateMyProfileWithData(Map<String, dynamic> data) {
  //   //td //del
  //   final UserProfile? currentProfile = _userProfile.value;
  //   if (currentProfile == null) return;
  //   _firestoreService.updateMyProfile(data);
  // }

  void clear() {
    _profileSubscription?.cancel();
    _profileSubscription = null;
    _userProfile.value = null;
  }

  @override
  void onClose() {
    _profileSubscription?.cancel();
    _profileSubscription = null;
    _userProfile.value = null;
    super.onClose();
  }
}
