import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:pow_wow/app/data/models/user_profile.dart';
import 'package:pow_wow/app/services/tribe_members_cache_storage.dart';

import 'subscription_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TribeMembersCacheStorage', () {
    late TribeMembersCacheStorage storage;

    setUpAll(() async {
      await configureFakePathProviderForTests();
      await GetStorage.init();
      storage = TribeMembersCacheStorage();
    });

    setUp(() async {
      await storage.clear(ownerUid: 'owner-1', tribeId: 'tribe-1');
      await storage.clear(ownerUid: 'owner-1', tribeId: 'tribe-2');
      await storage.clear(ownerUid: 'owner-2', tribeId: 'tribe-1');
    });

    test('returns null when nothing is cached', () {
      expect(storage.read(ownerUid: 'owner-1', tribeId: 'tribe-1'), isNull);
    });

    test('round-trips profiles and metadata', () async {
      final DateTime savedAt = DateTime.utc(2026, 7, 30, 10, 15);
      const List<UserProfile> profiles = <UserProfile>[
        UserProfile(
          uid: 'owner-1',
          name: 'Owner',
          avatarUrl: null,
          tribeId: 'tribe-1',
        ),
        UserProfile(
          uid: 'member-1',
          name: 'Member',
          avatarUrl: 'https://example.test/avatar.png',
          tribeId: 'tribe-1',
        ),
      ];

      await storage.write(
        ownerUid: 'owner-1',
        tribeId: 'tribe-1',
        profiles: profiles,
        savedAt: savedAt,
      );

      final TribeMembersCacheEntry? cached = storage.read(
        ownerUid: 'owner-1',
        tribeId: 'tribe-1',
      );

      expect(cached, isNotNull);
      expect(cached!.ownerUid, 'owner-1');
      expect(cached.tribeId, 'tribe-1');
      expect(cached.savedAt, savedAt);
      expect(cached.profiles, hasLength(2));
      expect(cached.profiles.last.uid, 'member-1');
      expect(cached.profiles.last.avatarUrl, profiles.last.avatarUrl);
    });

    test('keeps owners and tribes isolated', () async {
      await storage.write(
        ownerUid: 'owner-1',
        tribeId: 'tribe-1',
        profiles: const <UserProfile>[
          UserProfile(
            uid: 'owner-1',
            name: 'Owner',
            avatarUrl: null,
            tribeId: 'tribe-1',
          ),
        ],
      );

      expect(storage.read(ownerUid: 'owner-1', tribeId: 'tribe-1'), isNotNull);
      expect(storage.read(ownerUid: 'owner-1', tribeId: 'tribe-2'), isNull);
      expect(storage.read(ownerUid: 'owner-2', tribeId: 'tribe-1'), isNull);
    });

    test('rejects a cached member from another tribe', () {
      expect(
        () => TribeMembersCacheEntry.fromJson(<String, dynamic>{
          'version': TribeMembersCacheEntry.currentVersion,
          'ownerUid': 'owner-1',
          'tribeId': 'tribe-1',
          'savedAt': DateTime.utc(2026, 7, 30).toIso8601String(),
          'profiles': <Map<String, dynamic>>[
            const UserProfile(
              uid: 'member-1',
              name: 'Wrong tribe',
              avatarUrl: null,
              tribeId: 'tribe-2',
            ).toMap(),
          ],
        }),
        throwsFormatException,
      );
    });

    test('clear removes only the targeted cache', () async {
      await storage.write(
        ownerUid: 'owner-1',
        tribeId: 'tribe-1',
        profiles: const <UserProfile>[],
      );
      await storage.write(
        ownerUid: 'owner-1',
        tribeId: 'tribe-2',
        profiles: const <UserProfile>[],
      );

      await storage.clear(ownerUid: 'owner-1', tribeId: 'tribe-1');

      expect(storage.read(ownerUid: 'owner-1', tribeId: 'tribe-1'), isNull);
      expect(storage.read(ownerUid: 'owner-1', tribeId: 'tribe-2'), isNotNull);
    });
  });
}
