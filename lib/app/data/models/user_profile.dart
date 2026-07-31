class UserProfile {
  final String uid;
  final String name;
  final String? avatarUrl;
  final String tribeId;

  const UserProfile({
    required this.uid,
    required this.name,
    required this.avatarUrl,
    required this.tribeId,
  });

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    final String uid = map['uid'] as String? ?? '';
    return UserProfile(
      uid: uid,
      name: map['name'] as String? ?? '',
      avatarUrl: map['avatarUrl'] as String?,
      tribeId: map['tribeId'] as String? ?? uid,
    );
  }

  Map<String, dynamic> toMap() {
    final data = <String, dynamic>{
      'uid': uid,
      'name': name,
      'tribeId': tribeId,
    };
    if (avatarUrl != null) {
      data['avatarUrl'] = avatarUrl;
    }
    return data;
  }

  Map<String, dynamic> updatedData(UserProfile newValue) {
    final Map<String, dynamic> result = {};

    if (name != newValue.name) {
      result['name'] = newValue.name;
    }
    if (avatarUrl != newValue.avatarUrl) {
      result['avatarUrl'] = newValue.avatarUrl;
    }
    if (tribeId != newValue.tribeId) {
      result['tribeId'] = newValue.tribeId;
    }
    return result;
  }

  UserProfile copyWith({String? name, String? avatarUrl, String? tribeId}) {
    return UserProfile(
      uid: uid,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      tribeId: tribeId ?? this.tribeId,
    );
  }
}
