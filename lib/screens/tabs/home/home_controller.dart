import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/widgets.dart';
import 'package:pow_wow/app/data/models/user_profile.dart';
import 'package:pow_wow/app/services/api_service.dart';
import 'package:pow_wow/app/utils/bootstrap_error_helper.dart';
import 'package:pow_wow/app/utils/retry_error_log_helper.dart';
import 'package:pow_wow/app/utils/screen_helper.dart';
import 'package:get/get.dart';
import 'package:livekit_client/livekit_client.dart' show DisconnectReason;
import 'package:permission_handler/permission_handler.dart';

import '../../../app/data/enums/tribe_member_status.dart';
import '../../../app/data/models/tribe_members_snapshot.dart';
import '../../../app/data/models/tribe_message.dart';
import '../../../app/routes/app_routes.dart';
import '../../../app/settings_storage.dart';
import '../../../app/services/call_session_coordinator.dart';
import '../../../app/services/firebase/auth_service.dart';
import '../../../app/services/firebase/firestore_service.dart';
import '../../../app/data/models/tribe_member.dart';
import '../../../app/services/invite_link_service.dart';
import '../../../app/services/tribe_members_cache_storage.dart';
import '../../../main.dart';
import '../../../test_screen/test_log_helper.dart';
import 'live_kit_controller.dart';
import 'livekit_recovery_policy.dart';

class HomeController extends GetxController {
  final _apiService = ApiService();
  final _authService = Get.find<AuthService>();
  final FirestoreService _firestoreService = FirestoreService();
  final InviteLinkService _inviteLinkService = InviteLinkService();
  final TribeMembersCacheStorage _membersCache = TribeMembersCacheStorage();
  late UserProfile _myProfile;
  bool _isProfileReady = false;
  bool get isProfileReady => _isProfileReady;
  late LiveKitController _liveKitController;
  LiveKitController? get liveKitController => _liveKitController;

  StreamSubscription<TribeMembersSnapshot>? _membersSubscription;
  StreamSubscription<UserProfile?>? _myUserSubscription;
  int _membersListenerGeneration = 0;

  final List<UserProfile> _usersProfiles = [];
  List<UserProfile> get usersProfiles => _usersProfiles;
  List<TribeMember> get members => _buildMembers();
  List<TribeMember> get familyMembers =>
      members.where((member) => member.id != _myProfile.uid).toList();
  int get activeFamilyMembersCount => familyMembers
      .where((member) => member.status != CallMemberStatus.silent)
      .length;
  int get activeRoomMembersCount => members
      .where((member) => member.status != CallMemberStatus.silent)
      .length;
  bool get canCallTheTribe => activeRoomMembersCount >= 2;

  /// True when members have loaded and there is at least one other person in
  /// the current tribe. Works regardless of whether this user is the "owner"
  /// of the tribe or joined someone else's tribe via invite.
  bool get canLeaveTribe => _membersSynced && familyMembers.isNotEmpty;
  bool get canUseMemberActions => _membersSynced;
  UserProfile get myProfile => _myProfile;
  bool _isFetchingLiveKitToken = false;
  bool get isFetchingLiveKitToken => _isFetchingLiveKitToken;
  bool get isLiveKitJoinInProgress =>
      _isFetchingLiveKitToken || _liveKitController.isConnecting;

  String? connectionErrorMessage;
  bool connectionErrorIsNetwork = false;
  Object? _lastLiveKitFetchError;

  TribeMessage? lastMessage;
  bool _isPressingTalk = false;
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  bool _membersLoaded = false;
  bool get membersLoaded => _membersLoaded;
  bool _membersSynced = false;
  bool get membersSynced => _membersSynced;
  bool _hasHydratedMembersCache = false;
  bool _shouldMaintainLiveKitConnection = false;
  bool _isClosing = false;
  bool _isLiveKitRecoveryRunning = false;
  int _liveKitRecoveryAttempt = 0;
  Timer? _liveKitRecoveryTimer;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  DateTime? _liveKitRecoveryStartedAt;

  List<Duration> get _activeRecoveryRetryDelays =>
      liveKitRecoveryRetryDelaysFor(_appLifecycleState);

  @override
  void onInit() {
    super.onInit();

    // _liveKitController инициализируется первым: onClose() обращается к нему
    // независимо от того, завершился ли onInit() полностью.
    _liveKitController = LiveKitController(
      onUpdate: update,
      onUnexpectedDisconnect: _handleUnexpectedLiveKitDisconnect,
    );

    final UserProfile? profile = _authService.myProfile;
    if (profile == null) {
      // В нормальном флоу профиль всегда установлен SplashScreen до навигации
      // на dashboard. Этот guard защищает от race-condition при cold-start
      // (входящий звонок, deep link) и от потенциальных ошибок маршрутизации.
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'onInit_missing_profile',
          data: {
            'hasPendingAcceptedCall':
                callSessionCoordinator.hasPendingAcceptedCall,
          },
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Get.offAllNamed(AppRoutes.splash);
      });
      return;
    }
    _myProfile = profile;
    _isProfileReady = true;

    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    unawaited(_liveKitController.setAppLifecycleState(_appLifecycleState));
    unawaited(_loadIntercomVolume());
    _setProfiles([]);
    _hydrateMembersCache(tribeId: _myProfile.tribeId, tag: 'ON_INIT');

    _myUserSubscription = _authService.stream.listen((UserProfile? uProfile) {
      if (uProfile == null) return;

      final String previousTribeId = _myProfile.tribeId;
      _myProfile = uProfile;

      if (uProfile.tribeId != previousTribeId) {
        testPrintLS(
          DiagnosticLog.flow(
            'HomeController',
            'tribe_id_changed_externally',
            data: {
              'previousTribeId': previousTribeId,
              'newTribeId': uProfile.tribeId,
            },
          ),
        );
        unawaited(
          _switchTribe(
            uProfile.tribeId,
            tag: 'EXTERNAL',
            previousTribeId: previousTribeId,
          ),
        );
      } else {
        update();
      }
    });

    if (callSessionCoordinator.hasPendingAcceptedCall) {
      final bool enableMic =
          GetPlatform.isAndroid ||
          callSessionCoordinator.shouldEnableMicForAcceptedCall;
      final bool prewarmMic =
          GetPlatform.isAndroid ||
          callSessionCoordinator.shouldEnableMicForAcceptedCall;
      testPrintLS(
        'HC:: onInit: accepted incoming call pending → connectForIncomingCall(enableMic=$enableMic, prewarmMic=$prewarmMic)',
      );
      unawaited(
        connectForIncomingCall(enableMic: enableMic, prewarmMic: prewarmMic),
      );
    }

    if (GetPlatform.isAndroid) {
      _checkBluetoothPermissions();
    }

    _initAsync();
  }

  @override
  void onClose() {
    _isClosing = true;
    _shouldMaintainLiveKitConnection = false;
    _cancelLiveKitRecovery(source: 'controller_close');
    unawaited(
      _liveKitController.setBackgroundRecoveryActive(
        false,
        source: 'controller_close',
      ),
    );
    _inviteLinkService.dispose();
    _liveKitController.dispose();
    _membersSubscription?.cancel();
    _myUserSubscription?.cancel();
    super.onClose();
  }

  Future<void> _initAsync() async {
    testPrintLS('HC:: _initAsync...');
    _ensurePermissions();
    if (GetPlatform.isIOS) {
      await refreshIncomingCallRingingState(source: 'HC::_initAsync');
    }
    final inviteTribeId = await _inviteLinkService.getInitalTribeId();
    testPrintLS('HC:: _initAsync: inviteTribeId = $inviteTribeId');
    final String? newTribeId =
        inviteTribeId != null && inviteTribeId != _myProfile.tribeId
        ? inviteTribeId
        : null;

    _inviteLinkService.startListening(
      onRoomReceived: _handleIncomingRoomInvite,
    );

    if (newTribeId != null) {
      final uProfile = _myProfile.copyWith(tribeId: newTribeId);
      _myProfile = uProfile;
      _authService.updateMyProfile(uProfile);
    }

    _startMembersListener(
      tribeId: newTribeId ?? _myProfile.tribeId,
      tag: 'INIT',
    );

    //printAllProfiles();//td
    //printAllTokens();
  }

  // void setTestRoom() {
  //   //td
  //   _handleIncomingRoomInvite('KWnVVf5tAFU32ZqUehzZbzFQD962');
  //   //_handleIncomingRoomInvite('1111');
  // }

  Future<void> sendCall(TribeMember member) async {
    if (!_membersSynced) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'send_call_blocked_members_not_synced',
          data: {'memberId': member.id, 'memberName': member.name},
        ),
      );
      ScreenHelper.showSnackbar(
        '',
        'Updating tribe members. Try again shortly.',
      );
      return;
    }
    if (Get.find<AuthService>().uid == member.id) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'send_call_blocked_self',
          data: {'memberId': member.id, 'memberName': member.name},
        ),
      );
      return;
    }
    if (member.status != CallMemberStatus.silent) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'send_call_blocked_status',
          data: {
            'memberId': member.id,
            'memberName': member.name,
            'status': member.status.name,
          },
        ),
      );
      return;
    }

    _isLoading = true;
    update();
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'send_call_started',
        data: {
          'memberId': member.id,
          'memberName': member.name,
          'tribeId': _myProfile.tribeId,
        },
      ),
    );

    try {
      await _apiService.sendIncomingCall(
        userId: member.id,
        tribeId: _myProfile.tribeId,
      );
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'send_call_succeeded',
          data: {
            'memberId': member.id,
            'memberName': member.name,
            'tribeId': _myProfile.tribeId,
          },
        ),
      );
      ScreenHelper.showSendCallSnackbar(member.name);
    } catch (e) {
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'send_call_failed',
          data: {'memberId': member.id, 'memberName': member.name, 'error': e},
        ),
      );
      ScreenHelper.showSendCallErrorSnackbar(
        recipientName: member.name,
        error: e,
      );
    } finally {
      _isLoading = false;
      update();
    }
  }

  Future<void> switchToRoom(String roomId) => _handleIncomingRoomInvite(roomId);

  Future<void> _ensurePermissions() async {
    //td check if needed
    await [
      Permission.microphone,
      if (GetPlatform.isAndroid)
        Permission.bluetoothConnect, // Important for Android 12+
    ].request();
  }

  Future<void> leaveTribe() async {
    if (!canLeaveTribe) {
      return;
    }
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'leave_tribe_started',
        data: {
          'currentTribeId': _myProfile.tribeId,
          'ownTribeId': _myProfile.uid,
        },
      ),
    );
    await _switchTribe(const Uuid().v4(), tag: 'LEAVE');
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'leave_tribe_completed',
        data: {'tribeId': _myProfile.tribeId},
      ),
    );
  }

  Future<void> removeMemberFromTribe(TribeMember member) async {
    if (!_membersSynced) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'remove_member_blocked_members_not_synced',
          data: {'memberId': member.id, 'memberName': member.name},
        ),
      );
      throw StateError('Tribe members are still syncing');
    }
    final String newTribeId = const Uuid().v4();
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'remove_member_started',
        data: {
          'memberId': member.id,
          'memberName': member.name,
          'currentTribeId': _myProfile.tribeId,
          'newTribeId': newTribeId,
        },
      ),
    );
    await _firestoreService.updateUserTribeId(member.id, newTribeId);
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'remove_member_completed',
        data: {'memberId': member.id, 'memberName': member.name},
      ),
    );
  }

  Future<void> _handleIncomingRoomInvite(String roomId) async {
    testPrintLS(
      'HC:: _handleIncomingRoomInvite: roomId: $roomId, currentRoomId: ${_myProfile.tribeId}',
    );
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'room_invite_received',
        data: {'roomId': roomId, 'currentRoomId': _myProfile.tribeId},
      ),
    );
    if (_myProfile.tribeId == roomId) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'room_invite_ignored_same_room',
          data: {'roomId': roomId},
        ),
      );
      return;
    }

    await _switchTribe(roomId, tag: 'INV');
  }

  Future<void> _switchTribe(
    String newTribeId, {
    required String tag,
    String? previousTribeId,
  }) async {
    final String oldTribeId = previousTribeId ?? _myProfile.tribeId;
    final uProfile = _myProfile.copyWith(tribeId: newTribeId);
    _myProfile = uProfile;
    _authService.updateMyProfile(uProfile);
    _membersSubscription?.cancel();
    _membersSubscription = null;
    ++_membersListenerGeneration;
    _membersLoaded = false;
    _membersSynced = false;
    _hasHydratedMembersCache = false;
    _setProfiles([]);
    _hydrateMembersCache(tribeId: uProfile.tribeId, tag: tag);
    if (oldTribeId != uProfile.tribeId) {
      unawaited(
        _membersCache.clear(ownerUid: _myProfile.uid, tribeId: oldTribeId),
      );
    }
    _shouldMaintainLiveKitConnection = false;
    _cancelLiveKitRecovery(source: 'room_switch');
    await _liveKitController.setBackgroundRecoveryActive(
      false,
      source: 'room_switch',
    );

    if (_liveKitController.isConnected) {
      await _liveKitController.disconnect();
    }
    _startMembersListener(tribeId: uProfile.tribeId, tag: tag);
  }

  List<TribeMember> _buildMembers() {
    return _usersProfiles.map((e) {
      final status = _liveKitController.getStatus(userId: e.uid);
      return TribeMember(
        id: e.uid,
        name: e.name,
        avatarUrl: e.avatarUrl,
        status: status,
      );
    }).toList();
  }

  Future<void> _checkBluetoothPermissions() async {
    var status = await Permission.bluetooth.request();
    if (status.isPermanentlyDenied) {
      testPrintLS('HC:: _checkPermissions: Bluetooth Permission disabled');
    }

    status = await Permission.bluetoothConnect.request();
    if (status.isPermanentlyDenied) {
      testPrintLS(
        'HC:: _checkPermissions: Bluetooth Connect Permission disabled',
      );
    }
  }

  void _setProfiles(List<UserProfile> profiles) {
    final List<UserProfile> nextProfiles = profiles.isEmpty
        ? [_myProfile]
        : profiles;

    _usersProfiles.assignAll(nextProfiles);
    update();
  }

  void clearConnectionError() {
    if (connectionErrorMessage == null) {
      return;
    }

    logRetryErrorBannerCleared(
      scope: 'HomeController',
      reason: 'connection_restored',
    );
    connectionErrorMessage = null;
    connectionErrorIsNetwork = false;
    update();
  }

  void _showConnectionErrorBanner({
    required String message,
    required bool isNetworkError,
    required String source,
    String? errorType,
  }) {
    connectionErrorMessage = message;
    connectionErrorIsNetwork = isNetworkError;
    update();
    logRetryErrorBannerShown(
      scope: 'HomeController',
      message: message,
      isNetworkError: isNetworkError,
      source: source,
      layout: 'compact',
    );
    if (errorType != null) {
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'connection_error_banner_context',
          data: <String, Object?>{'source': source, 'errorType': errorType},
        ),
      );
    }
  }

  void _setConnectionError(Object error, {required String source}) {
    _showConnectionErrorBanner(
      message: bootstrapErrorMessage(error),
      isNetworkError: isNetworkBootstrapError(error),
      source: source,
      errorType: error.runtimeType.toString(),
    );
  }

  void _setRecoveryExhaustedConnectionError({required String source}) {
    // Background recovery failures are invisible to the user; on resume we start
    // a fresh connect instead of surfacing stale errors.
    if (_appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    // While app_resumed auto-connect is in flight, a parallel exhausted recovery
    // must not flash a misleading banner.
    if (isLiveKitJoinInProgress) {
      return;
    }

    _showConnectionErrorBanner(
      message: bootstrapConnectionErrorMessage,
      isNetworkError: true,
      source: source,
    );
  }

  void _markLiveKitRecoveryStarted() {
    _liveKitRecoveryStartedAt ??= DateTime.now();
  }

  String _liveKitRecoveryExhaustedReason() {
    if (_liveKitRecoveryAttempt >= _activeRecoveryRetryDelays.length) {
      return 'attempts_exhausted';
    }

    if (_appLifecycleState == AppLifecycleState.resumed &&
        _liveKitRecoveryStartedAt != null &&
        DateTime.now().difference(_liveKitRecoveryStartedAt!) >
            liveKitForegroundRecoveryMaxDuration) {
      return 'foreground_budget_exceeded';
    }

    return 'unknown';
  }

  bool _isLiveKitRecoveryExhausted() {
    return isLiveKitRecoveryExhausted(
      lifecycleState: _appLifecycleState,
      attemptCount: _liveKitRecoveryAttempt,
      recoveryStartedAt: _liveKitRecoveryStartedAt,
    );
  }

  void _exhaustLiveKitRecovery({required String source}) {
    testPrintLS(
      DiagnosticLog.err(
        'HomeController',
        'livekit_recovery_exhausted',
        data: <String, Object?>{
          'source': source,
          'attempts': _liveKitRecoveryAttempt,
          'lifecycle': _appLifecycleState.name,
          'exhaustedReason': _liveKitRecoveryExhaustedReason(),
          'maxAttempts': _activeRecoveryRetryDelays.length,
        },
      ),
    );
    unawaited(
      _liveKitController.setBackgroundRecoveryActive(
        false,
        source: '${source}_exhausted',
      ),
    );
    _setRecoveryExhaustedConnectionError(source: source);
  }

  Future<void> retryConnection() async {
    logRetryErrorTryAgainTapped(
      scope: 'HomeController',
      source: 'home_connection_banner',
    );
    clearConnectionError();
    _resetLiveKitRecovery(source: 'manual_retry');
    // Force-disconnect any stuck/zombie join so the next connect starts clean.
    // Without this, isConnecting=true blocks _connectLiveKit and Try again is a no-op.
    if (_liveKitController.isConnecting || _liveKitController.isConnected) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'retry_force_disconnect',
          data: {
            'wasConnecting': _liveKitController.isConnecting,
            'wasConnected': _liveKitController.isConnected,
          },
        ),
      );
      await _liveKitController.disconnect();
    }
    callSessionCoordinator.reset();
    _startMembersListener(tribeId: _myProfile.tribeId, tag: 'RETRY');
    await _reevaluateTribeAutoConnect(
      source: 'retry_connection',
      origin: CallSessionOrigin.manualRetry,
    );
  }

  Future<bool> _connectLiveKit({
    bool prewarmMic = true,
    bool showErrors = true,
    CallSessionOrigin origin = CallSessionOrigin.none,
  }) async {
    if (_liveKitController.isConnected) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'connect_livekit_skipped_already_connected',
        ),
      );
      return true;
    }

    if (_liveKitController.isConnecting || _isFetchingLiveKitToken) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'connect_livekit_skipped_busy',
          data: {
            'isConnecting': _liveKitController.isConnecting,
            'isFetchingToken': _isFetchingLiveKitToken,
          },
        ),
      );
      return false;
    }

    final bool shouldPrewarmMic =
        prewarmMic &&
        (!GetPlatform.isIOS ||
            callSessionCoordinator.shouldEnableMicForAcceptedCall);
    _markCallSessionConnectionStarted(origin);
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'connect_livekit_started',
        data: {
          'tribeId': _myProfile.tribeId,
          'prewarmMic': shouldPrewarmMic,
          'hasPendingAcceptedCall':
              callSessionCoordinator.hasPendingAcceptedCall,
        },
      ),
    );
    _isFetchingLiveKitToken = true;
    update();
    final liveKitConnection = await _fetchLiveKitToken();
    _isFetchingLiveKitToken = false;
    update();
    if (liveKitConnection == null) {
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'connect_livekit_aborted_missing_token',
          data: {'tribeId': _myProfile.tribeId},
        ),
      );
      if (showErrors) {
        _setConnectionError(
          _lastLiveKitFetchError ?? StateError('fetchLiveKitToken'),
          source: 'connect_livekit_missing_token',
        );
      }
      callSessionCoordinator.failed();
      return false;
    }

    await _loadIntercomVolume();
    final error = await _liveKitController.connect(
      url: liveKitConnection.url,
      token: liveKitConnection.token,
      prewarmMic: shouldPrewarmMic,
    );
    if (error != null) {
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'connect_livekit_failed',
          data: {'tribeId': _myProfile.tribeId, 'error': error},
        ),
      );
      if (showErrors) {
        _showConnectionErrorBanner(
          message: error,
          isNetworkError: error == bootstrapConnectionErrorMessage,
          source: 'connect_livekit_failed',
          errorType: error,
        );
      }
      callSessionCoordinator.failed();
      return false;
    }

    clearConnectionError();
    callSessionCoordinator.connected();

    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'connect_livekit_succeeded',
        data: {
          'tribeId': _myProfile.tribeId,
          'isConnected': _liveKitController.isConnected,
        },
      ),
    );
    _resetLiveKitRecovery(source: 'connect_livekit_succeeded');
    return true;
  }

  Future<void> _loadIntercomVolume() async {
    final double intercomVolume = await SettingsStorage.getIntercomVolume();
    await _liveKitController.setIntercomVolume(intercomVolume);
  }

  void _setShouldMaintainLiveKitConnection(
    bool value, {
    required String source,
  }) {
    if (_shouldMaintainLiveKitConnection == value) {
      if (!value) {
        _cancelLiveKitRecovery(source: source);
        unawaited(
          _liveKitController.setBackgroundRecoveryActive(false, source: source),
        );
      }
      return;
    }

    _shouldMaintainLiveKitConnection = value;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'livekit_maintain_state_changed',
        data: {'value': value, 'source': source},
      ),
    );

    if (!value) {
      _cancelLiveKitRecovery(source: source);
      unawaited(
        _liveKitController.setBackgroundRecoveryActive(false, source: source),
      );
    }
  }

  bool _handleUnexpectedLiveKitDisconnect(DisconnectReason? reason) {
    testPrintLS(
      DiagnosticLog.warn(
        'HomeController',
        'livekit_unexpected_disconnect',
        data: {
          'reason': reason?.name ?? 'unknown',
          'shouldMaintain': _shouldMaintainLiveKitConnection,
        },
      ),
    );
    return _scheduleLiveKitRecoveryIfNeeded(
      source: 'room_disconnected_event',
      reason: reason,
    );
  }

  void handlePlatformDispatcherError(Object error) {
    final bool isLiveKitMediaError = _liveKitController.markRtcMediaPathFailed(
      source: 'platform_dispatcher',
      error: error,
    );
    if (!isLiveKitMediaError) return;

    testPrintLS(
      DiagnosticLog.warn(
        'HomeController',
        'livekit_media_path_recovery_requested',
        data: {'lifecycle': _appLifecycleState.name},
      ),
    );

    if (_appLifecycleState == AppLifecycleState.resumed) {
      unawaited(_recoverLiveKitMediaPathFailure());
    }
  }

  Future<void> _recoverLiveKitMediaPathFailure() async {
    if (!_shouldMaintainLiveKitConnection || _isClosing) return;
    if (_liveKitController.isConnected ||
        _liveKitController.isRoomConnectionInFlight) {
      await _liveKitController.disconnect();
    }
    await _reevaluateTribeAutoConnect(source: 'rtc_media_path_failed');
  }

  bool _scheduleLiveKitRecoveryIfNeeded({
    required String source,
    required DisconnectReason? reason,
    bool immediate = false,
  }) {
    if (_isClosing) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_skipped_closing',
          data: {'source': source},
        ),
      );
      return false;
    }

    if (!_shouldMaintainLiveKitConnection) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_skipped_not_expected',
          data: {'source': source, 'reason': reason?.name ?? 'unknown'},
        ),
      );
      return false;
    }

    if (_liveKitController.isConnected) {
      _resetLiveKitRecovery(source: '${source}_already_connected');
      return false;
    }

    if (_liveKitController.isConnecting ||
        _isFetchingLiveKitToken ||
        _isLiveKitRecoveryRunning) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_skipped_busy',
          data: {
            'source': source,
            'isConnecting': _liveKitController.isConnecting,
            'isFetchingToken': _isFetchingLiveKitToken,
            'isRecoveryRunning': _isLiveKitRecoveryRunning,
          },
        ),
      );
      return true;
    }

    if (_isLiveKitRecoveryExhausted()) {
      _exhaustLiveKitRecovery(source: source);
      return false;
    }

    _markLiveKitRecoveryStarted();

    final bool hasPendingRecovery = _liveKitRecoveryTimer?.isActive == true;
    if (hasPendingRecovery && !immediate) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_skipped_timer_pending',
          data: {'source': source},
        ),
      );
      return true;
    }

    if (hasPendingRecovery && immediate) {
      _cancelLiveKitRecovery(source: '${source}_immediate');
    }

    final Duration delay = immediate
        ? Duration.zero
        : _activeRecoveryRetryDelays[_liveKitRecoveryAttempt];
    final int attemptNumber = _liveKitRecoveryAttempt + 1;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        immediate
            ? 'livekit_recovery_resume_scheduled'
            : 'livekit_recovery_scheduled',
        data: {
          'source': source,
          'attempt': attemptNumber,
          'delayMs': delay.inMilliseconds,
          'lifecycle': _appLifecycleState.name,
          'maxAttempts': _activeRecoveryRetryDelays.length,
          'reason': reason?.name ?? 'unknown',
        },
      ),
    );

    _liveKitRecoveryTimer = Timer(delay, () {
      _liveKitRecoveryTimer = null;
      unawaited(_runLiveKitRecoveryAttempt(source: source, reason: reason));
    });
    return true;
  }

  Future<void> _runLiveKitRecoveryAttempt({
    required String source,
    required DisconnectReason? reason,
  }) async {
    if (_isLiveKitRecoveryRunning) return;

    if (_isLiveKitRecoveryExhausted()) {
      await _liveKitController.setBackgroundRecoveryActive(
        false,
        source: '${source}_attempt_exhausted',
      );
      _setRecoveryExhaustedConnectionError(source: source);
      return;
    }

    _markLiveKitRecoveryStarted();

    if (!_shouldMaintainLiveKitConnection || _isClosing) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_attempt_aborted',
          data: {
            'source': source,
            'shouldMaintain': _shouldMaintainLiveKitConnection,
            'isClosing': _isClosing,
          },
        ),
      );
      await _liveKitController.setBackgroundRecoveryActive(
        false,
        source: '${source}_aborted',
      );
      return;
    }

    if (_liveKitController.isConnected) {
      _resetLiveKitRecovery(source: '${source}_already_connected');
      return;
    }

    if (_liveKitController.isConnecting || _isFetchingLiveKitToken) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'livekit_recovery_attempt_skipped_busy',
          data: {
            'source': source,
            'isConnecting': _liveKitController.isConnecting,
            'isFetchingToken': _isFetchingLiveKitToken,
          },
        ),
      );
      if (_liveKitRecoveryAttempt == 0) {
        _liveKitRecoveryAttempt = 1;
      }
      _scheduleLiveKitRecoveryIfNeeded(source: source, reason: reason);
      return;
    }

    _isLiveKitRecoveryRunning = true;
    final int attemptNumber = _liveKitRecoveryAttempt + 1;
    _liveKitRecoveryAttempt++;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'livekit_recovery_attempt_started',
        data: {
          'source': source,
          'attempt': attemptNumber,
          'reason': reason?.name ?? 'unknown',
        },
      ),
    );

    try {
      final bool didConnect = await _connectLiveKit(
        prewarmMic: false,
        showErrors: false,
        origin: CallSessionOrigin.recovery,
      );
      if (didConnect) {
        testPrintLS(
          DiagnosticLog.flow(
            'HomeController',
            'livekit_recovery_succeeded',
            data: {'source': source, 'attempt': attemptNumber},
          ),
        );
        _resetLiveKitRecovery(source: '${source}_succeeded');
        return;
      }

      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'livekit_recovery_failed',
          data: {'source': source, 'attempt': attemptNumber},
        ),
      );
    } finally {
      _isLiveKitRecoveryRunning = false;
    }

    _scheduleLiveKitRecoveryIfNeeded(source: source, reason: reason);
  }

  void _resetLiveKitRecovery({required String source}) {
    _cancelLiveKitRecovery(source: source);
    unawaited(
      _liveKitController.setBackgroundRecoveryActive(false, source: source),
    );
    if (_liveKitRecoveryAttempt == 0 && _liveKitRecoveryStartedAt == null) {
      return;
    }

    _liveKitRecoveryAttempt = 0;
    _liveKitRecoveryStartedAt = null;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'livekit_recovery_reset',
        data: {'source': source},
      ),
    );
  }

  /// Clears stale background recovery state when the user returns to the app.
  /// Does not show error banners — [handleAppLifecycleState] starts a fresh
  /// auto-connect in foreground instead.
  void _prepareLiveKitRecoveryForForegroundResume() {
    clearConnectionError();
    _resetLiveKitRecovery(source: 'app_resumed');
  }

  /// Resets any in-flight SDK reconnect before a fresh foreground join, then
  /// auto-connects once. Recovery runs only if the room is still disconnected.
  Future<void> _handleLiveKitOnForegroundResume() async {
    final bool hadResume = _liveKitController.consumeAndClearResumeFlag();
    final bool reconnectedInBackground = _liveKitController
        .consumeAndClearBackgroundReconnectFlag();
    final bool mediaPathFailed = _liveKitController
        .consumeAndClearRtcMediaPathFailedFlag();
    final bool skipZombieDisconnect = _shouldSkipZombieDisconnectOnResume();
    final bool shouldForceZombieDisconnect =
        shouldForceDisconnectAfterBackgroundResume(
          hadResumeInBackground: hadResume,
          isConnected: _liveKitController.isConnected,
          skipForCallSession: skipZombieDisconnect,
          reconnectedInBackground: reconnectedInBackground,
          mediaPathFailed: mediaPathFailed,
        );

    if (_shouldMaintainLiveKitConnection) {
      if (shouldForceZombieDisconnect) {
        testPrintLS(
          DiagnosticLog.warn(
            'HomeController',
            'zombie_disconnect_on_resume',
            data: {
              'source': 'app_resumed',
              'hadResumeInBackground': true,
              'reconnectedInBackground': reconnectedInBackground,
              'mediaPathFailed': mediaPathFailed,
            },
          ),
        );
        await _liveKitController.disconnect();
      } else if ((skipZombieDisconnect || reconnectedInBackground) &&
          hadResume &&
          _liveKitController.isConnected) {
        final callFlags = callSessionCoordinator.diagnosticFlags;
        testPrintLS(
          DiagnosticLog.flow(
            'HomeController',
            'zombie_disconnect_skipped',
            data: {
              'source': 'app_resumed',
              'reason': reconnectedInBackground
                  ? 'background_reconnected'
                  : 'call_session',
              'reconnectedInBackground': reconnectedInBackground,
              'pendingCallAccept': callFlags.pendingCallAccept,
              'incomingCallRinging': callFlags.incomingCallRinging,
              'pendingAcceptedCallId': callFlags.pendingAcceptedCallId,
              'iosCallkitAudioSessionActive':
                  callFlags.iosCallkitAudioSessionActive,
            },
          ),
        );
      } else if (!_liveKitController.isConnected &&
          _liveKitController.isRoomConnectionInFlight) {
        testPrintLS(
          DiagnosticLog.flow(
            'HomeController',
            'stale_room_session_cancelled',
            data: {
              'source': 'app_resumed',
              'hadResumeInBackground': hadResume,
              'connectionState': _liveKitController.roomConnectionStateName,
            },
          ),
        );
        await _liveKitController.disconnect();
      }
    }

    await _reevaluateTribeAutoConnect(source: 'app_resumed');

    if (!_shouldMaintainLiveKitConnection) {
      return;
    }
    if (_liveKitController.isConnected || _liveKitController.isConnecting) {
      return;
    }

    _scheduleLiveKitRecoveryIfNeeded(
      source: 'app_resumed',
      reason: null,
      immediate: true,
    );
  }

  void _cancelLiveKitRecovery({required String source}) {
    final bool hadTimer = _liveKitRecoveryTimer != null;
    _liveKitRecoveryTimer?.cancel();
    _liveKitRecoveryTimer = null;

    if (!hadTimer) return;

    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'livekit_recovery_cancelled',
        data: {'source': source},
      ),
    );
  }

  Future<LiveKitConnectionDetails?> _fetchLiveKitToken() async {
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'fetch_livekit_token_started',
        data: {'tribeId': _myProfile.tribeId, 'userId': _myProfile.uid},
      ),
    );
    _lastLiveKitFetchError = null;
    try {
      final result = await _apiService.fetchLiveKitToken(
        userId: _myProfile.uid,
        tribeId: _myProfile.tribeId,
        name: _myProfile.name,
      );
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'fetch_livekit_token_succeeded',
          data: {
            'tribeId': _myProfile.tribeId,
            'hasToken': result.token.isNotEmpty,
            'hasUrl': result.url.isNotEmpty,
          },
        ),
      );
      return result;
    } catch (e) {
      _lastLiveKitFetchError = e;
      testPrintLS('HC:: _fetchLiveKitToken: ❌ ERROR = $e');
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'fetch_livekit_token_failed',
          data: {'tribeId': _myProfile.tribeId, 'error': e},
        ),
      );
      return null;
    }
  }

  Future<bool> _resolveShouldAutoConnect(int memberCount) async {
    if (memberCount <= 1 ||
        callSessionCoordinator.shouldBlockTribeAutoConnect) {
      return false;
    }

    if (!GetPlatform.isIOS) {
      return true;
    }

    final bool nativeIncomingCallRinging =
        await refreshIncomingCallRingingState(
          source: 'HC::resolveShouldAutoConnect',
        );
    return !nativeIncomingCallRinging;
  }

  Future<void> _applyTribeAutoConnect({
    required String source,
    required List<UserProfile> profiles,
    required bool isValidTribe,
    CallSessionOrigin origin = CallSessionOrigin.autoJoin,
  }) async {
    if (!isValidTribe) {
      _setShouldMaintainLiveKitConnection(
        false,
        source: '${source}_invalid_tribe',
      );
      return;
    }

    final bool shouldAutoConnect = await _resolveShouldAutoConnect(
      profiles.length,
    );
    final callFlags = callSessionCoordinator.diagnosticFlags;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'tribe_auto_connect_evaluated',
        data: {
          'source': source,
          'count': profiles.length,
          'shouldAutoConnect': shouldAutoConnect,
          'incomingCallRinging': callFlags.incomingCallRinging,
          'pendingCallAccept': callFlags.pendingCallAccept,
          'iosDeclinedBeforeForeground':
              callFlags.iosDeclinedIncomingCallBeforeForeground,
        },
      ),
    );

    _setShouldMaintainLiveKitConnection(shouldAutoConnect, source: source);
    if (!shouldAutoConnect) {
      return;
    }

    if (!_liveKitController.isConnected && !_liveKitController.isConnecting) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'auto_connect_requested',
          data: {'source': source, 'tribeId': _myProfile.tribeId},
        ),
      );
      await _connectLiveKit(origin: origin);
      return;
    }

    _scheduleLiveKitRecoveryIfNeeded(
      source: source,
      reason: null,
      immediate: true,
    );
  }

  Future<void> _reevaluateTribeAutoConnect({
    required String source,
    CallSessionOrigin origin = CallSessionOrigin.autoJoin,
  }) async {
    if (_isClosing || !_membersSynced || _usersProfiles.isEmpty) {
      return;
    }

    final bool isValidTribe =
        _usersProfiles.firstOrNull == null ||
        _usersProfiles.firstOrNull!.tribeId == _myProfile.tribeId;
    await _applyTribeAutoConnect(
      source: source,
      profiles: _usersProfiles,
      isValidTribe: isValidTribe,
      origin: origin,
    );
  }

  void _markCallSessionConnectionStarted(CallSessionOrigin origin) {
    switch (origin) {
      case CallSessionOrigin.autoJoin:
        callSessionCoordinator.autoJoinStarted();
        break;
      case CallSessionOrigin.manualRetry:
        callSessionCoordinator.manualRetryStarted();
        break;
      case CallSessionOrigin.recovery:
        callSessionCoordinator.recoveryStarted();
        break;
      case CallSessionOrigin.none:
      case CallSessionOrigin.incomingCall:
        break;
    }
  }

  void _startMembersListener({required String tribeId, required String tag}) {
    final String normalizedTribeId = tribeId.trim();
    testPrintLS(
      'HC:: [$tag] _startMembersListener: tribeId = $normalizedTribeId',
    );
    _membersSubscription?.cancel();
    _membersSubscription = null;
    _membersSynced = false;
    _hasHydratedMembersCache = false;
    final int generation = ++_membersListenerGeneration;
    final bool cacheLoaded = _hydrateMembersCache(
      tribeId: normalizedTribeId,
      tag: tag,
    );
    if (!cacheLoaded) {
      _membersLoaded = false;
      _setProfiles([]);
    } else {
      update();
    }

    _membersSubscription = _firestoreService
        .watchMemberSnapshots(normalizedTribeId)
        .listen(
          (TribeMembersSnapshot snapshot) {
            if (generation != _membersListenerGeneration || _isClosing) {
              return;
            }
            _applyMembersSnapshot(
              profiles: snapshot.profiles,
              tribeId: normalizedTribeId,
              source: snapshot.isFromCache
                  ? 'members_cache_$tag'
                  : 'members_server_$tag',
              isFromCache: snapshot.isFromCache,
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            if (generation != _membersListenerGeneration || _isClosing) {
              return;
            }
            if (!_membersLoaded) {
              _membersLoaded = true;
            }
            _membersSynced = false;
            update();
            testPrintLS('HC:: ❌ watchMembers error: $error');
            testPrintLS(
              DiagnosticLog.err(
                'HomeController',
                'watch_members_failed',
                data: <String, Object?>{
                  'tribeId': normalizedTribeId,
                  'errorType': error.runtimeType.toString(),
                },
              ),
            );
            _setConnectionError(error, source: 'watch_members_stream');
          },
        );
  }

  bool _hydrateMembersCache({required String tribeId, required String tag}) {
    if (tribeId != _myProfile.tribeId) {
      return false;
    }

    final TribeMembersCacheEntry? cached = _membersCache.read(
      ownerUid: _myProfile.uid,
      tribeId: tribeId,
    );
    if (cached == null) {
      return false;
    }

    _membersLoaded = true;
    _membersSynced = false;
    _hasHydratedMembersCache = true;
    _setProfiles(cached.profiles);
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'members_cache_loaded',
        data: {
          'tag': tag,
          'tribeId': tribeId,
          'count': cached.profiles.length,
          'ageSeconds': DateTime.now()
              .toUtc()
              .difference(cached.savedAt)
              .inSeconds,
        },
      ),
    );
    return true;
  }

  void _applyMembersSnapshot({
    required List<UserProfile> profiles,
    required String tribeId,
    required String source,
    required bool isFromCache,
  }) {
    final bool isValidTribe =
        tribeId == _myProfile.tribeId &&
        profiles.every((UserProfile profile) => profile.tribeId == tribeId);
    testPrintLS(
      'HC:: $source: isValidTribe: $isValidTribe, count=${profiles.length}, fromCache=$isFromCache',
    );
    final callFlags = callSessionCoordinator.diagnosticFlags;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'members_updated',
        data: {
          'source': source,
          'tribeId': tribeId,
          'count': profiles.length,
          'isValidTribe': isValidTribe,
          'isFromCache': isFromCache,
          'incomingCallRinging': callFlags.incomingCallRinging,
          'pendingCallAccept': callFlags.pendingCallAccept,
        },
      ),
    );

    if (isValidTribe) {
      if (isFromCache &&
          profiles.isEmpty &&
          _hasHydratedMembersCache &&
          familyMembers.isNotEmpty) {
        testPrintLS(
          DiagnosticLog.flow(
            'HomeController',
            'members_empty_firestore_cache_ignored',
            data: {'source': source, 'tribeId': tribeId},
          ),
        );
        return;
      }

      _membersLoaded = true;
      if (!isFromCache) {
        _membersSynced = true;
        _hasHydratedMembersCache = false;
      }
      _setProfiles(profiles);

      if (isFromCache) {
        return;
      }

      clearConnectionError();
      unawaited(
        _writeMembersCache(
          tribeId: tribeId,
          profiles: profiles,
          source: source,
        ),
      );
      unawaited(
        _applyTribeAutoConnectAfterMembersSync(
          source: source,
          profiles: profiles,
        ),
      );
    } else {
      _membersSynced = false;
      _setShouldMaintainLiveKitConnection(
        false,
        source: 'members_invalid_tribe',
      );
    }
  }

  Future<void> _writeMembersCache({
    required String tribeId,
    required List<UserProfile> profiles,
    required String source,
  }) async {
    if (_isClosing || tribeId != _myProfile.tribeId) {
      return;
    }

    try {
      await _membersCache.write(
        ownerUid: _myProfile.uid,
        tribeId: tribeId,
        profiles: profiles,
      );
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'members_cache_written',
          data: {
            'source': source,
            'tribeId': tribeId,
            'count': profiles.length,
          },
        ),
      );
    } catch (error) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'members_cache_write_failed',
          data: {'source': source, 'error': error.toString()},
        ),
      );
    }
  }

  Future<void> _applyTribeAutoConnectAfterMembersSync({
    required String source,
    required List<UserProfile> profiles,
  }) async {
    try {
      await _applyTribeAutoConnect(
        source: source,
        profiles: profiles,
        isValidTribe: true,
      );
    } catch (error) {
      testPrintLS(
        DiagnosticLog.err(
          'HomeController',
          'tribe_auto_connect_failed_after_members_sync',
          data: {'source': source, 'error': error.toString()},
        ),
      );
      _setConnectionError(error, source: 'tribe_auto_connect_after_members');
    }
  }

  Future<void> startTalking() async {
    _isPressingTalk = true;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'start_talking_requested',
        data: {
          'isConnected': _liveKitController.isConnected,
          'isConnecting': _liveKitController.isConnecting,
        },
      ),
    );

    if (!_liveKitController.isConnected) {
      if (_liveKitController.isConnecting || _isFetchingLiveKitToken) {
        testPrintLS(
          'HC::  startTalking: ❗️ LiveKit.isConnecting/isFetchingToken',
        );
        testPrintLS(
          DiagnosticLog.warn(
            'HomeController',
            'start_talking_blocked_connecting',
            data: {
              'isConnecting': _liveKitController.isConnecting,
              'isFetchingToken': _isFetchingLiveKitToken,
            },
          ),
        );
        // Queue mic enable for when the in-flight connection completes.
        // If the user releases before that, stopTalking → setMicEnabled(false)
        // will clear _enableMicAfterConnect automatically.
        await _liveKitController.setMicEnabled(true);
        return;
      }
      await _connectLiveKit(origin: CallSessionOrigin.autoJoin);
    }

    if (!_isPressingTalk || !_liveKitController.isConnected) {
      testPrintLS(
        DiagnosticLog.warn(
          'HomeController',
          'start_talking_skipped',
          data: {
            'isPressingTalk': _isPressingTalk,
            'isConnected': _liveKitController.isConnected,
          },
        ),
      );
      return;
    }

    HapticFeedback.mediumImpact();
    await _liveKitController.setMicEnabled(true);
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'mic_enable_requested',
        data: {'isConnected': _liveKitController.isConnected},
      ),
    );
  }

  Future<void> stopTalking() async {
    _isPressingTalk = false;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'stop_talking_requested',
        data: {'isConnected': _liveKitController.isConnected},
      ),
    );
    HapticFeedback.selectionClick();
    await _liveKitController.setMicEnabled(false);
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'mic_disable_requested',
        data: {'isConnected': _liveKitController.isConnected},
      ),
    );
  }

  bool _shouldSkipZombieDisconnectOnResume() {
    return callSessionCoordinator.shouldSkipZombieDisconnectOnResume;
  }

  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    final AppLifecycleState previousLifecycle = _appLifecycleState;
    _appLifecycleState = state;
    testPrintLS(
      DiagnosticLog.flow(
        'HomeController',
        'app_lifecycle_changed',
        data: <String, Object?>{
          'from': previousLifecycle.name,
          'to': state.name,
          'recoveryAttempt': _liveKitRecoveryAttempt,
        },
      ),
    );
    await _liveKitController.setAppLifecycleState(state);

    if (previousLifecycle != AppLifecycleState.resumed &&
        state == AppLifecycleState.resumed) {
      _prepareLiveKitRecoveryForForegroundResume();
    }

    if (state == AppLifecycleState.resumed) {
      await _handleLiveKitOnForegroundResume();
    }
  }

  // Called when the user accepts an incoming CallKit call.
  // On iOS we stay listen-only after a normal foreground resume, but when the
  // user remains on the native CallKit screen we can start with mic enabled so
  // the system mute button and LiveKit track stay in sync.
  Future<void> connectForIncomingCall({
    required bool enableMic,
    bool prewarmMic = true,
  }) async {
    testPrintLS(
      'HC:: 🟠🟠🟠 connectForIncomingCall(enableMic=$enableMic, prewarmMic=$prewarmMic)',
    );

    if (isLiveKitJoinInProgress) {
      testPrintLS(
        DiagnosticLog.flow(
          'HomeController',
          'incoming_call_connect_skipped_busy',
          data: {
            'isConnecting': _liveKitController.isConnecting,
            'isFetchingToken': _isFetchingLiveKitToken,
          },
        ),
      );
      return;
    }

    _setShouldMaintainLiveKitConnection(true, source: 'incoming_call_accept');
    // setMicEnabled queues the desired post-connect mic state when not yet
    // connected so connect() can apply it after joining the room.
    await _liveKitController.setMicEnabled(enableMic);
    if (!_liveKitController.isConnected && !_liveKitController.isConnecting) {
      await _connectLiveKit(prewarmMic: prewarmMic);
    }
    if (_liveKitController.isConnected) {
      callSessionCoordinator.connected();
    }
  }

  /// Called when the user declines an incoming CallKit call or ends it.
  Future<void> handleCallDeclined() async {
    testPrintLS('HC:: handleCallDeclined');

    await _liveKitController.setMicEnabled(false);
    await _liveKitController.forceStopBackgroundWhiteNoise(
      source: 'call_declined',
    );
    await _liveKitController.syncBackgroundWhiteNoiseAfterCallFlowChange(
      source: 'call_declined',
    );

    if (_liveKitController.isConnected || _liveKitController.isConnecting) {
      await _liveKitController.disconnect();
    }

    await _reevaluateTribeAutoConnect(source: 'call_declined');
  }

  /// Called when the native CallKit Mute button is toggled.
  Future<void> handleMuteToggled(bool muted) async {
    testPrintLS('HC:: handleMuteToggled: muted=$muted');
    await _liveKitController.setMicEnabled(!muted);
  }

  /// Re-sync background white noise when an incoming CallKit call starts ringing.
  Future<void> handleIncomingCallRingingChanged() async {
    await _liveKitController.syncBackgroundWhiteNoiseAfterCallFlowChange(
      source: 'incoming_call_ringing',
    );
  }

  /// Called when CallKit activates or releases the shared AVAudioSession.
  Future<void> handleCallkitAudioSessionToggled(bool isActivate) async {
    if (isActivate) {
      await _liveKitController.onCallkitAudioSessionActivated();
    } else {
      await _liveKitController.onCallkitAudioSessionDeactivated();
    }
  }
}
