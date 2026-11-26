import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:pow_wow/app/services/first_run_access.dart';
import 'package:pow_wow/app/services/first_run_router.dart';
import 'package:pow_wow/app/services/subscriptions/subscription_store_gateway.dart';

import 'subscription_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FirstRunAccess', () {
    late FirstRunAccess access;

    setUpAll(() async {
      await configureFakePathProviderForTests();
      await GetStorage.init();
    });

    setUp(() async {
      await GetStorage().erase();
      access = FirstRunAccess();
    });

    test('new user without a plan can neither enter nor talk', () {
      expect(access.canEnterApp(hasEntitlement: false), isFalse);
      expect(access.canTalk(hasEntitlement: false), isFalse);
    });

    test('subscriber can enter and talk', () {
      expect(access.canEnterApp(hasEntitlement: true), isTrue);
      expect(access.canTalk(hasEntitlement: true), isTrue);
    });

    test('"Not now" lets the user in but not talk', () async {
      await access.deferPaywall();
      expect(access.canEnterApp(hasEntitlement: false), isTrue);
      expect(access.canTalk(hasEntitlement: false), isFalse);
    });

    test('an invite from family lets the user in and talk', () async {
      final bool recorded = await access.recordInvite('tribe-1', ownUid: 'me');
      expect(recorded, isTrue);
      expect(access.pendingInviteRoomId, 'tribe-1');
      expect(access.canEnterApp(hasEntitlement: false), isTrue);
      expect(access.canTalk(hasEntitlement: false), isTrue);

      await access.clearPendingInvite();
      expect(access.pendingInviteRoomId, isNull);
      expect(access.canTalk(hasEntitlement: false), isTrue);
    });

    test('an invite to your own family does not unlock talking', () async {
      expect(await access.recordInvite('me', ownUid: 'me'), isFalse);
      expect(await access.recordInvite('  ', ownUid: 'me'), isFalse);
      expect(access.canTalk(hasEntitlement: false), isFalse);
    });

    test('review prompt is requested once, on the third session', () async {
      expect(await access.recordTalkSessionWithFamily(), isFalse);
      expect(await access.recordTalkSessionWithFamily(), isFalse);
      expect(await access.recordTalkSessionWithFamily(), isTrue);
      expect(await access.recordTalkSessionWithFamily(), isFalse);
    });
  });

  group('decideFirstRunDestination', () {
    FirstRunDestination decide({
      bool hasEntitlement = false,
      bool paywallDeferred = false,
      bool joinedViaInvite = false,
      bool inviteStepSeen = false,
      bool isNewProfile = false,
    }) {
      return decideFirstRunDestination(
        hasEntitlement: hasEntitlement,
        paywallDeferred: paywallDeferred,
        joinedViaInvite: joinedViaInvite,
        inviteStepSeen: inviteStepSeen,
        isNewProfile: isNewProfile,
      );
    }

    test('new profile goes to the invite step first', () {
      expect(decide(isNewProfile: true), FirstRunDestination.inviteStep);
    });

    test('after the invite step, the paywall', () {
      expect(
        decide(isNewProfile: true, inviteStepSeen: true),
        FirstRunDestination.paywall,
      );
      expect(decide(), FirstRunDestination.paywall);
    });

    test('invited members and subscribers go straight to Home', () {
      expect(
        decide(isNewProfile: true, joinedViaInvite: true),
        FirstRunDestination.dashboard,
      );
      expect(decide(hasEntitlement: true), FirstRunDestination.dashboard);
      expect(decide(paywallDeferred: true), FirstRunDestination.dashboard);
    });
  });

  group('isoPeriodToDays', () {
    test('parses store trial periods', () {
      expect(isoPeriodToDays('P3D'), 3);
      expect(isoPeriodToDays('P1W'), 7);
      expect(isoPeriodToDays('P1M'), 30);
      expect(isoPeriodToDays('P1Y'), 365);
      expect(isoPeriodToDays(''), isNull);
      expect(isoPeriodToDays(null), isNull);
      expect(isoPeriodToDays('junk'), isNull);
    });
  });
}
