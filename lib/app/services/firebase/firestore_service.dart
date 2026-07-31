import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import '../../data/models/tribe_members_snapshot.dart';
import '../../data/models/user_profile.dart';

class FirestoreService {
  FirestoreService({FirebaseAuth? auth, FirebaseFirestore? firestore})
    : _auth = auth ?? FirebaseAuth.instance,
      _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _usersCollection =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _tokensCollection =>
      _firestore.collection('tokens');

  String get _currentUid {
    final User? user = _auth.currentUser;
    if (user == null) {
      throw Exception('User is not authorized');
    }
    return user.uid;
  }

  Future<void> updateMyProfile(Map<String, dynamic> data) async {
    testPrintLS('FirestoreService:: updateMyProfile: data = $data');
    await _usersCollection.doc(_currentUid).set(data, SetOptions(merge: true));
  }

  Future<void> updateUserTribeId(String uid, String newTribeId) async {
    testPrintLS(
      'FirestoreService:: updateUserTribeId: uid=$uid, newTribeId=$newTribeId',
    );
    await _usersCollection.doc(uid).set({
      'tribeId': newTribeId,
    }, SetOptions(merge: true));
  }

  Future<List<UserProfile>> tribeMembers(String tribeId) async {
    final String normalizedTribeId = tribeId.trim();

    if (normalizedTribeId.isEmpty) {
      return <UserProfile>[];
    }

    final QuerySnapshot<Map<String, dynamic>> snapshot = await _usersCollection
        .where('tribeId', isEqualTo: normalizedTribeId)
        .get();

    return snapshot.docs.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
      return UserProfile.fromMap(doc.data());
    }).toList();
  }

  Future<List<UserProfile>> fetchAllProfiles() async {
    //td //test
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _usersCollection
        .get();

    return snapshot.docs.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
      return UserProfile.fromMap(doc.data());
    }).toList();
  }

  Stream<UserProfile?> watchMyProfile() {
    return _usersCollection.doc(_currentUid).snapshots().map((
      DocumentSnapshot<Map<String, dynamic>> doc,
    ) {
      final Map<String, dynamic>? data = doc.data();
      return data != null ? UserProfile.fromMap(data) : null;
    });
  }

  Stream<List<UserProfile>> watchMembers(String tribeId) {
    final String normalizedTribeId = tribeId.trim();

    if (normalizedTribeId.isEmpty) {
      return Stream<List<UserProfile>>.value(<UserProfile>[]);
    }

    return _usersCollection
        .where('tribeId', isEqualTo: normalizedTribeId)
        .snapshots()
        .map((QuerySnapshot<Map<String, dynamic>> snapshot) {
          return snapshot.docs.map((
            QueryDocumentSnapshot<Map<String, dynamic>> doc,
          ) {
            return UserProfile.fromMap(doc.data());
          }).toList();
        });
  }

  Stream<TribeMembersSnapshot> watchMemberSnapshots(String tribeId) {
    final String normalizedTribeId = tribeId.trim();

    if (normalizedTribeId.isEmpty) {
      return Stream<TribeMembersSnapshot>.value(
        const TribeMembersSnapshot(
          profiles: <UserProfile>[],
          isFromCache: false,
        ),
      );
    }

    return _usersCollection
        .where('tribeId', isEqualTo: normalizedTribeId)
        .snapshots(includeMetadataChanges: true)
        .map((QuerySnapshot<Map<String, dynamic>> snapshot) {
          final List<UserProfile> profiles = snapshot.docs.map((
            QueryDocumentSnapshot<Map<String, dynamic>> doc,
          ) {
            return UserProfile.fromMap(doc.data());
          }).toList();
          return TribeMembersSnapshot(
            profiles: profiles,
            isFromCache: snapshot.metadata.isFromCache,
          );
        });
  }

  Future<UserProfile> createProfile({
    required String username,
    String? avatarUrl,
    String? tribeId,
  }) async {
    final UserProfile profile = UserProfile(
      uid: _currentUid,
      name: username.trim(),
      avatarUrl: avatarUrl,
      tribeId: tribeId ?? _currentUid,
    );

    await _usersCollection.doc(_currentUid).set(profile.toMap());
    return profile;
  }

  Future<void> setTokenVoIP({
    required String token,
    required String userId,
  }) async {
    final String pushEnvironment = 'production';
    //final String pushEnvironment = 'development'; //td del after test
    final Map<String, dynamic> data = {
      'userId': userId,
      'tokenVoIP': token,
      'platform': 'ios',
      'apnsTopic': 'com.gys.powwow.voip',
      'pushEnvironment': pushEnvironment,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    testPrintLS(
      DiagnosticLog.flow(
        'FirestoreService',
        'set_voip_token',
        data: {
          'userId': userId,
          'voipPreview': _shortTokenPreview(token),
          'voipChars': token.length,
          'platform': 'ios',
          'apnsTopic': 'com.gys.powwow.voip',
          'pushEnvironment': pushEnvironment,
        },
      ),
    );
    await _tokensCollection.doc(userId).set(data, SetOptions(merge: true));
  }

  Future<void> setTokenFCM({
    required String token,
    required String userId,
  }) async {
    final Map<String, dynamic> data = {
      'userId': userId,
      'tokenFCM': token,
      'platform': 'android',
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await _tokensCollection.doc(userId).set(data, SetOptions(merge: true));
  }

  Future<List<Map<String, dynamic>>> fetchAllTokens() async {
    //td //test
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _tokensCollection
        .get();

    return snapshot.docs.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
      return doc.data();
    }).toList();
  }

  Future<void> deleteUserProfile() async {
    await _usersCollection.doc(_currentUid).delete();
  }

  Future<void> deleteProfileByUid(String uid) async {
    await _usersCollection.doc(uid).delete();
  }

  Future<UserProfile?> getMyProfile() async {
    final DocumentSnapshot<Map<String, dynamic>> doc = await _usersCollection
        .doc(_currentUid)
        .get();

    final Map<String, dynamic>? data = doc.data();
    if (data == null) {
      return null;
    }

    return UserProfile.fromMap(data);
  }

  Future<Map<String, dynamic>?> getRawProfileByUid(String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> doc = await _usersCollection
        .doc(uid)
        .get();
    return doc.data();
  }

  Future<void> writeProfileForUid(String uid, Map<String, dynamic> data) async {
    await _usersCollection.doc(uid).set(data);
  }

  String _shortTokenPreview(String token) {
    final String normalized = token.trim();
    if (normalized.length <= 12) {
      return normalized;
    }
    return '${normalized.substring(0, 6)}...${normalized.substring(normalized.length - 6)}';
  }
}
