import 'package:get_storage/get_storage.dart';

import '../data/models/user_profile.dart';

class TribeMembersCacheEntry {
  static const int currentVersion = 1;

  final String ownerUid;
  final String tribeId;
  final DateTime savedAt;
  final List<UserProfile> profiles;

  const TribeMembersCacheEntry({
    required this.ownerUid,
    required this.tribeId,
    required this.savedAt,
    required this.profiles,
  });

  factory TribeMembersCacheEntry.fromJson(Map<String, dynamic> json) {
    if (json['version'] != currentVersion) {
      throw const FormatException('Unsupported tribe members cache version');
    }

    final String ownerUid = (json['ownerUid'] as String? ?? '').trim();
    final String tribeId = (json['tribeId'] as String? ?? '').trim();
    final DateTime? savedAt = DateTime.tryParse(
      json['savedAt'] as String? ?? '',
    );
    final Object? rawProfiles = json['profiles'];

    if (ownerUid.isEmpty ||
        tribeId.isEmpty ||
        savedAt == null ||
        rawProfiles is! List) {
      throw const FormatException('Invalid tribe members cache entry');
    }

    final List<UserProfile> profiles = rawProfiles
        .map((Object? rawProfile) {
          if (rawProfile is! Map) {
            throw const FormatException('Invalid cached tribe member');
          }
          final UserProfile profile = UserProfile.fromMap(
            Map<String, dynamic>.from(rawProfile),
          );
          if (profile.uid.trim().isEmpty || profile.tribeId != tribeId) {
            throw const FormatException(
              'Cached member belongs to another tribe',
            );
          }
          return profile;
        })
        .toList(growable: false);

    return TribeMembersCacheEntry(
      ownerUid: ownerUid,
      tribeId: tribeId,
      savedAt: savedAt.toUtc(),
      profiles: profiles,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'version': currentVersion,
      'ownerUid': ownerUid,
      'tribeId': tribeId,
      'savedAt': savedAt.toUtc().toIso8601String(),
      'profiles': profiles
          .map((UserProfile profile) => profile.toMap())
          .toList(),
    };
  }
}

class TribeMembersCacheStorage {
  TribeMembersCacheStorage({GetStorage? box}) : _box = box ?? GetStorage();

  static const String _keyPrefix = 'tribe_members_cache_v1';

  final GetStorage _box;

  TribeMembersCacheEntry? read({
    required String ownerUid,
    required String tribeId,
  }) {
    final String normalizedOwnerUid = ownerUid.trim();
    final String normalizedTribeId = tribeId.trim();
    if (normalizedOwnerUid.isEmpty || normalizedTribeId.isEmpty) {
      return null;
    }

    final Object? raw = _box.read(
      _key(ownerUid: normalizedOwnerUid, tribeId: normalizedTribeId),
    );
    if (raw is! Map) {
      return null;
    }

    try {
      final TribeMembersCacheEntry entry = TribeMembersCacheEntry.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (entry.ownerUid != normalizedOwnerUid ||
          entry.tribeId != normalizedTribeId) {
        return null;
      }
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> write({
    required String ownerUid,
    required String tribeId,
    required List<UserProfile> profiles,
    DateTime? savedAt,
  }) {
    final String normalizedOwnerUid = ownerUid.trim();
    final String normalizedTribeId = tribeId.trim();
    if (normalizedOwnerUid.isEmpty || normalizedTribeId.isEmpty) {
      return Future<void>.value();
    }

    final TribeMembersCacheEntry entry = TribeMembersCacheEntry(
      ownerUid: normalizedOwnerUid,
      tribeId: normalizedTribeId,
      savedAt: (savedAt ?? DateTime.now()).toUtc(),
      profiles: List<UserProfile>.unmodifiable(profiles),
    );
    return _box.write(
      _key(ownerUid: normalizedOwnerUid, tribeId: normalizedTribeId),
      entry.toJson(),
    );
  }

  Future<void> clear({required String ownerUid, required String tribeId}) {
    final String normalizedOwnerUid = ownerUid.trim();
    final String normalizedTribeId = tribeId.trim();
    if (normalizedOwnerUid.isEmpty || normalizedTribeId.isEmpty) {
      return Future<void>.value();
    }
    return _box.remove(
      _key(ownerUid: normalizedOwnerUid, tribeId: normalizedTribeId),
    );
  }

  String _key({required String ownerUid, required String tribeId}) {
    return '${_keyPrefix}_${ownerUid}_$tribeId';
  }
}
