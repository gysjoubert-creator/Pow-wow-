import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'app/routes/app_pages.dart';
import 'app/routes/app_routes.dart';
import 'app/services/call_session_coordinator.dart';
import 'app/services/firebase/auth_service.dart';
import 'app/services/firebase/firestore_service.dart';
import 'app/services/onboarding_storage.dart';
import 'app/services/subscriptions/subscription_service.dart';
import 'app/utils/callkit_state_helper.dart';
import 'screens/tabs/home/home_controller.dart';
import 'test_screen/test_logs_screen_controller.dart';

final FirestoreService _firestoreService = FirestoreService();
final CallSessionCoordinator callSessionCoordinator = CallSessionCoordinator();

String? _callkitCallIdFromBody(dynamic body) {
  if (body is! Map) return null;

  return body['id']?.toString() ??
      body['callUUID']?.toString() ??
      body['uuid']?.toString();
}

Future<List<Map<String, dynamic>>> fetchActiveCallkitCalls() async {
  final dynamic result = await FlutterCallkitIncoming.activeCalls();
  if (result is! List) {
    return <Map<String, dynamic>>[];
  }

  return normalizeActiveCallkitCalls(result);
}

Future<bool> refreshIncomingCallRingingState({
  required String source,
  List<dynamic>? activeCalls,
}) async {
  if (!GetPlatform.isIOS) return callSessionCoordinator.isIncomingCallRinging;

  final List<Map<String, dynamic>> calls = activeCalls != null
      ? normalizeActiveCallkitCalls(activeCalls)
      : await fetchActiveCallkitCalls();
  final bool nextState = hasRingingCallkitCall(calls);
  final bool previousState = callSessionCoordinator.isIncomingCallRinging;

  if (nextState) {
    Map<String, dynamic>? ringingCall;
    for (final call in calls) {
      if (call['accepted'] != true) {
        ringingCall = call;
        break;
      }
    }
    callSessionCoordinator.incomingCallRinging(
      callkitCallId:
          ringingCall?['id']?.toString() ?? ringingCall?['uuid']?.toString(),
    );
  } else if (callSessionCoordinator.phase == CallSessionPhase.ringing) {
    callSessionCoordinator.ended();
  }
  final bool currentState = callSessionCoordinator.isIncomingCallRinging;

  if (previousState != currentState) {
    testPrintLS(
      'MAIN:: $source — incomingCallRinging $previousState → $currentState (activeCalls=${calls.length})',
    );
  }

  if (currentState && Get.isRegistered<HomeController>()) {
    unawaited(Get.find<HomeController>().handleIncomingCallRingingChanged());
  }
  return currentState;
}

String? _tokenFcmOrVoIP;
String? get tokenFcmOrVoIP => _tokenFcmOrVoIP;
Future<void> _setTokenFcmOrVoIP(String token) async {
  String? userId;
  if (Get.isRegistered<AuthService>()) {
    userId = Get.find<AuthService>().uid;
  }

  if (userId != null) {
    _tokenFcmOrVoIP = null;
    if (GetPlatform.isAndroid) {
      await _firestoreService.setTokenFCM(token: token, userId: userId);
    } else {
      await _firestoreService.setTokenVoIP(token: token, userId: userId);
    }
  } else {
    _tokenFcmOrVoIP = token;
  }
}

Future<String?> getVoIpToken() async {
  final rawValue = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
  if (rawValue == null) return null;

  final result = rawValue.toString().trim();
  return result.isNotEmpty ? result : null;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  Get.put<TestLogsScreenController>(
    TestLogsScreenController(),
    permanent: true,
  );
  await GetStorage.init();
  final platform = GetPlatform.isIOS ? 'iOS' : 'Android';
  testPrintLS('APP_STARTED: 🟩 🟩 🟩 $platform');

  await Firebase.initializeApp();

  // Flutter framework errors (build/layout/etc.) and async errors outside zones.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    testPrintLS('🧨 FlutterError: ${details.exceptionAsString()}');
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    testPrintLS('🧨 PlatformDispatcher error: $error');
    if (Get.isRegistered<HomeController>()) {
      Get.find<HomeController>().handlePlatformDispatcherError(error);
    }
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  Get.put<AuthService>(AuthService(), permanent: true);
  Get.put<SubscriptionService>(SubscriptionService(), permanent: true);

  runApp(const MyApp());
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  testPrintLS('================ BACKGROUND MESSAGE ================');
  testPrintLS('messageId: ${message.messageId}');
  testPrintLS('from: ${message.from}');
  testPrintLS('data: ${message.data}');
  testPrintLS('notification title: ${message.notification?.title}');
  testPrintLS('notification body: ${message.notification?.body}');
  testPrintLS('====================================================');

  final String type = message.data['type']?.toString() ?? '';
  final String uuid = message.data['callUUID']?.toString() ?? const Uuid().v4();
  final String callerName = message.data['callerName']?.toString() ?? 'Unknown';
  final String handle = message.data['handle']?.toString() ?? '';

  if (type == 'INCOMING_CALL') {
    await showCallkitIncoming(
      uuid: uuid,
      callerName: callerName,
      handle: handle,
    );
  }
}

Future<void> showCallkitIncoming({
  required String uuid,
  required String callerName,
  required String handle,
}) async {
  final CallKitParams params = CallKitParams(
    id: uuid,
    nameCaller: callerName,
    appName: 'Pow Wow',
    handle: handle,
    type: 0,
    duration: 30000,
    textAccept: 'Accept',
    textDecline: 'Decline',
    missedCallNotification: const NotificationParams(
      showNotification: true,
      isShowCallback: true,
      subtitle: 'Missed call',
      callbackText: 'Call back',
    ),
    extra: <String, dynamic>{
      'callUUID': uuid,
      'callerName': callerName,
      'handle': handle,
    },
    headers: <String, dynamic>{'platform': 'flutter'},
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: true,
      //logoUrl: 'assets/test.png',
      ringtonePath: 'system_ringtone_default',
      backgroundColor: '#0955fa',
      backgroundUrl: 'assets/test.png',
      actionColor: '#4CAF50',
      textColor: '#ffffff',
      incomingCallNotificationChannelName: 'Incoming Call',
      missedCallNotificationChannelName: 'Missed Call',
      isImportant: true,
    ),
    ios: const IOSParams(
      iconName: 'CallKitLogo',
      handleType: 'generic',
      supportsVideo: false,
      maximumCallGroups: 2,
      maximumCallsPerCallGroup: 1,
      audioSessionMode: 'voiceChat',
      audioSessionActive: true,
      audioSessionPreferredSampleRate: 44100.0,
      audioSessionPreferredIOBufferDuration: 0.005,
      supportsDTMF: true,
      supportsHolding: true,
      supportsGrouping: false,
      supportsUngrouping: false,
      ringtonePath: 'system_ringtone_default',
    ),
  );

  await FlutterCallkitIncoming.showCallkitIncoming(params);
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  FirebaseMessaging? _firebaseMessaging;
  StreamSubscription<CallEvent?>? _callkitSubscription;

  late final Uuid _uuid;
  bool _endingCallProgrammatically = false;

  @override
  void initState() {
    super.initState();

    _uuid = const Uuid();
    WidgetsBinding.instance.addObserver(this);
    if (GetPlatform.isAndroid) {
      FlutterCallkitIncoming.requestFullIntentPermission();
    }

    if (GetPlatform.isAndroid) {
      initFirebaseMessaging();
    } else {
      unawaited(_syncVoIPToken(source: 'app_init'));
      unawaited(refreshIncomingCallRingingState(source: 'initState'));
    }

    _startCallKitListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (GetPlatform.isAndroid) {
        // The `resumed` lifecycle event may fire before addObserver() is called
        // when the app starts from a killed state (Accept on incoming call).
        // This post-frame check guarantees we clean up any active CallKit calls
        // regardless of whether the lifecycle event was missed.
        unawaited(_endActiveCallkitCallsIfPresent());
      } else {
        // On iOS, Accept from a killed/locked state can launch the app without
        // replaying the CallKit accept event into Flutter. Recover from the
        // accepted native call record and continue inside the app.
        unawaited(_synchronizeIOSCallkitState(source: 'postFrame'));
      }
    });
  }

  Future<void> _endActiveCallkitCallsIfPresent() async {
    final dynamic result = await FlutterCallkitIncoming.activeCalls();
    if (result is List && result.isNotEmpty) {
      testPrintLS(
        'MAIN:: postFrame — found ${result.length} active CallKit call(s), ending...',
      );
      _endingCallProgrammatically = true;
      FlutterCallkitIncoming.endAllCalls();
    }
  }

  Future<void> _synchronizeIOSCallkitState({required String source}) async {
    final List<Map<String, dynamic>> activeCalls =
        await fetchActiveCallkitCalls();
    await refreshIncomingCallRingingState(
      source: '$source/sync',
      activeCalls: activeCalls,
    );
    if (activeCalls.isEmpty) return;

    final Map<String, dynamic>? acceptedCall = findAcceptedCallkitCall(
      activeCalls,
    );
    if (acceptedCall == null) {
      testPrintLS(
        'MAIN:: $source — found ${activeCalls.length} active CallKit call(s), but none accepted',
      );
      return;
    }

    final Object? callId = acceptedCall['id'] ?? acceptedCall['uuid'];
    testPrintLS(
      'MAIN:: $source — accepted CallKit call detected (id=$callId), resuming in app',
    );

    await _resumeAcceptedIncomingCallInApp(
      source: source,
      callkitCallId: callId?.toString(),
    );
  }

  Future<void> _resumeAcceptedIncomingCallInApp({
    required String source,
    String? callkitCallId,
  }) async {
    final AppLifecycleState? lifecycleState =
        WidgetsBinding.instance.lifecycleState;
    final bool shouldEnableMic =
        !GetPlatform.isIOS || lifecycleState != AppLifecycleState.resumed;
    callSessionCoordinator.incomingCallAccepted(
      callkitCallId:
          callkitCallId ??
          callSessionCoordinator.snapshot.callkitCallId ??
          callSessionCoordinator.acceptedCallId,
      enableMic: shouldEnableMic,
    );
    testPrintLS('MAIN:: incomingCallRinging → false (accepted)');
    final bool shouldEnableMicForAcceptedCall =
        callSessionCoordinator.shouldEnableMicForAcceptedCall;
    testPrintLS(
      'MAIN:: $source → accepted incoming call, enableMic=$shouldEnableMicForAcceptedCall',
    );

    if (Get.isRegistered<HomeController>()) {
      if (GetPlatform.isIOS && lifecycleState != AppLifecycleState.resumed) {
        testPrintLS(
          'MAIN:: $source → app not resumed yet ($lifecycleState), starting LiveKit in background and deferring CallKit cleanup',
        );
      }
      await Get.find<HomeController>().connectForIncomingCall(
        enableMic: shouldEnableMic,
        prewarmMic: shouldEnableMic,
      );
      return;
    }

    if (GetPlatform.isIOS &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      testPrintLS(
        'MAIN:: $source → waiting for HomeController/foreground to finish accepted-call resume',
      );
    }
  }

  Future<void> _waitForLiveKitJoinToSettle({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!Get.isRegistered<HomeController>()) return;

    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }

      final homeController = Get.find<HomeController>();
      final liveKitController = homeController.liveKitController;

      if (liveKitController == null) return;

      if (liveKitController.isConnected && !liveKitController.isConnecting) {
        return;
      }

      if (!homeController.isLiveKitJoinInProgress &&
          !liveKitController.isConnected) {
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _dismissAcceptedCallkitCallAfterForeground({
    required String source,
  }) async {
    if (!GetPlatform.isIOS) return;

    await _waitForLiveKitJoinToSettle();
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      testPrintLS(
        'MAIN:: $source — skip CallKit cleanup because app is no longer resumed',
      );
      return;
    }

    final List<Map<String, dynamic>> activeCalls =
        await fetchActiveCallkitCalls();
    final Map<String, dynamic>? acceptedCall = findAcceptedCallkitCall(
      activeCalls,
    );
    if (acceptedCall == null) return;

    final String? callId =
        callSessionCoordinator.acceptedCallId ??
        acceptedCall['id']?.toString() ??
        acceptedCall['uuid']?.toString();
    if (callId != null) {
      testPrintLS('MAIN:: $source — setCallConnected(id=$callId)');
      await FlutterCallkitIncoming.setCallConnected(callId);
    }

    testPrintLS(
      'MAIN:: $source — ending accepted CallKit call after app foregrounded',
    );
    _endingCallProgrammatically = true;
    callSessionCoordinator.callkitCleanupStarted();
    await FlutterCallkitIncoming.endAllCalls();
  }

  void _startCallKitListener() {
    _callkitSubscription = FlutterCallkitIncoming.onEvent.listen((
      CallEvent? event,
    ) {
      if (event == null) return;

      testPrintLS('MAIN:: CallKit event: ${event.event}');
      switch (event.event) {
        case Event.actionCallIncoming:
          callSessionCoordinator.incomingCallRinging(
            callkitCallId: _callkitCallIdFromBody(event.body),
          );
          testPrintLS('MAIN:: incomingCallRinging → true');
          if (Get.isRegistered<HomeController>()) {
            unawaited(
              Get.find<HomeController>().handleIncomingCallRingingChanged(),
            );
          }
          break;
        case Event.actionCallAccept:
          _onCallAccepted(callkitCallId: _callkitCallIdFromBody(event.body));
          break;
        case Event.actionCallDecline:
        case Event.actionCallEnded:
          _onCallDeclined();
          break;
        case Event.actionCallToggleMute:
          final bool muted = event.body['isMuted'] as bool? ?? false;
          _onCallMuteToggled(muted);
          break;
        case Event.actionCallToggleAudioSession:
          _onAudioSessionToggled(event.body['isActivate'] as bool? ?? true);
          break;
        case Event.actionDidUpdateDevicePushTokenVoip:
          if (GetPlatform.isIOS) {
            unawaited(_syncVoIPToken(source: 'callkit_event'));
          }
          break;
        default:
          break;
      }
    });
  }

  void _onCallAccepted({String? callkitCallId}) {
    if (GetPlatform.isIOS) {
      testPrintLS(
        'MAIN:: _onCallAccepted(iOS) → resuming accepted call and keeping CallKit active until foreground cleanup',
      );
      unawaited(
        _resumeAcceptedIncomingCallInApp(
          source: '_onCallAccepted(iOS)',
          callkitCallId: callkitCallId,
        ),
      );
      return;
    }

    testPrintLS('MAIN:: _onCallAccepted(Android) → connect with mic enabled');
    callSessionCoordinator.incomingCallAccepted(
      callkitCallId: callkitCallId,
      enableMic: true,
    );
    testPrintLS('MAIN:: incomingCallRinging → false (accepted)');
    if (Get.isRegistered<HomeController>()) {
      unawaited(
        Get.find<HomeController>().connectForIncomingCall(
          enableMic: true,
          prewarmMic: true,
        ),
      );
    }
    if (GetPlatform.isAndroid) {
      // End the CallKit/Telecom call record to remove the ongoing notification
      // (phone icon + timer) from the status bar. The LiveKit session continues
      // independently via flutter_foreground_task.
      _endingCallProgrammatically = true;
      FlutterCallkitIncoming.endAllCalls();
    }
  }

  void _onAudioSessionToggled(bool isActivate) {
    testPrintLS('MAIN:: _onAudioSessionToggled: isActivate=$isActivate');
    callSessionCoordinator.callkitAudioSessionToggled(isActivate);
    if (Get.isRegistered<HomeController>()) {
      unawaited(
        Get.find<HomeController>().handleCallkitAudioSessionToggled(isActivate),
      );
    }
  }

  void _onCallDeclined() {
    if (_endingCallProgrammatically) {
      callSessionCoordinator.callkitCleanupCompleted();
      _endingCallProgrammatically = false;
      testPrintLS('MAIN:: _onCallDeclined (suppressed — our own endAllCalls)');
      return;
    }
    final bool declinedBeforeForeground =
        GetPlatform.isIOS &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    callSessionCoordinator.incomingCallDeclined(
      beforeForeground: declinedBeforeForeground,
    );
    testPrintLS('MAIN:: incomingCallRinging → false (declined/ended)');
    if (declinedBeforeForeground) {
      testPrintLS(
        'MAIN:: declined incoming call before foreground — suppress background audio',
      );
    }

    testPrintLS('MAIN:: _onCallDeclined');
    if (Get.isRegistered<HomeController>()) {
      unawaited(Get.find<HomeController>().handleCallDeclined());
    }
  }

  void _onCallMuteToggled(bool muted) {
    testPrintLS('MAIN:: _onCallMuteToggled: muted=$muted');
    if (Get.isRegistered<HomeController>()) {
      Get.find<HomeController>().handleMuteToggled(muted);
    }
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    testPrintLS('MAIN:: LifecycleState: $state');

    if (state == AppLifecycleState.resumed &&
        GetPlatform.isIOS &&
        callSessionCoordinator.declinedBeforeForeground) {
      callSessionCoordinator.clearDeclinedBeforeForeground();
      testPrintLS(
        'MAIN:: resumed — cleared declined-before-foreground audio suppression',
      );
    }

    if (Get.isRegistered<HomeController>()) {
      await Get.find<HomeController>().handleAppLifecycleState(state);
    }

    if (state == AppLifecycleState.resumed &&
        Get.isRegistered<SubscriptionService>()) {
      unawaited(
        Get.find<SubscriptionService>().refreshEntitlement(silent: true),
      );
    }

    if (state == AppLifecycleState.resumed && GetPlatform.isAndroid) {
      // When the app was killed and the user pressed Accept on the incoming
      // call notification, actionCallAccept never fires (Flutter wasn't running).
      // We check here (fires on every foreground transition) for any active
      // CallKit/Telecom calls and end them so the ongoing notification
      // (phone icon + timer) is removed.
      final dynamic result = await FlutterCallkitIncoming.activeCalls();
      if (result is List && result.isNotEmpty) {
        testPrintLS(
          'MAIN:: resumed — found ${result.length} active CallKit call(s), ending...',
        );
        _endingCallProgrammatically = true;
        FlutterCallkitIncoming.endAllCalls();
      }
    } else if (state == AppLifecycleState.resumed && GetPlatform.isIOS) {
      if (callSessionCoordinator.hasPendingAcceptedCall) {
        final HomeController? homeController =
            Get.isRegistered<HomeController>()
            ? Get.find<HomeController>()
            : null;
        final liveKitController = homeController?.liveKitController;
        final bool joinAlreadyInProgress =
            homeController?.isLiveKitJoinInProgress ?? false;
        final bool acceptedCallAlreadyConnected =
            callSessionCoordinator.acceptedCallId != null &&
            (liveKitController?.isConnected ?? false);
        if (joinAlreadyInProgress || acceptedCallAlreadyConnected) {
          testPrintLS(
            'MAIN:: resumed/pendingCallAccept — skip duplicate resume (joinInProgress=$joinAlreadyInProgress, alreadyConnected=$acceptedCallAlreadyConnected)',
          );
        } else {
          await _resumeAcceptedIncomingCallInApp(
            source: 'resumed/pendingCallAccept',
          );
        }
        unawaited(
          _dismissAcceptedCallkitCallAfterForeground(
            source: 'resumed/pendingCallAccept',
          ),
        );
      } else {
        await _synchronizeIOSCallkitState(source: 'resumed');
        unawaited(
          _dismissAcceptedCallkitCallAfterForeground(source: 'resumed/sync'),
        );
      }
    }
  }

  @override
  void dispose() {
    _callkitSubscription?.cancel();
    _callkitSubscription = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _syncVoIPToken({required String source}) async {
    final result = await getVoIpToken();
    final String preview = result == null || result.length <= 12
        ? result ?? ''
        : '${result.substring(0, 6)}...${result.substring(result.length - 6)}';
    testPrintLS(
      "MAIN:: [IOS] devicePushTokenVoIP ($source) preview='$preview', chars=${result?.length ?? 0}",
    );
    if (result != null) {
      await _setTokenFcmOrVoIP(result);
    }
  }

  Future<void> initFirebaseMessaging() async {
    _firebaseMessaging = FirebaseMessaging.instance;

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      //td //check if needed
      testPrintLS(
        '### MAIN:: 🟣 FirebaseMessaging.onMessage.listen: '
        'Message title: ${message.notification?.title}, '
        'body: ${message.notification?.body}, data: ${message.data}',
      );

      final String type = message.data['type']?.toString() ?? '';
      final String uuid = message.data['callUUID']?.toString() ?? _uuid.v4();
      final String callerName =
          message.data['callerName']?.toString() ?? 'Unknown';
      final String handle = message.data['handle']?.toString() ?? '';

      if (type == 'INCOMING_CALL') {
        await showCallkitIncoming(
          uuid: uuid,
          callerName: callerName,
          handle: handle,
        );
      }
    });

    _firebaseMessaging?.getToken().then((token) {
      testPrintLS('MAIN:: [ANDROID] Device Token FCM: $token');
      if (token != null) {
        _setTokenFcmOrVoIP(token);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final String initialRoute = OnboardingStorage().isCompleted
        ? AppRoutes.splash
        : AppRoutes.onboarding;

    return GetMaterialApp(
      enableLog: true, //td
      logWriterCallback: (String text, {bool? isError}) {
        debugPrint(text);
        if (Get.isRegistered<TestLogsScreenController>()) {
          Get.find<TestLogsScreenController>().addMessage('GETX: $text');
        }
      }, //td
      defaultTransition: Transition.fadeIn,
      debugShowCheckedModeBanner: false,
      initialRoute: initialRoute,
      getPages: AppPages.pages,
      // Any route GetX can't match (e.g. a powwow:// invite link that reaches
      // the navigator) falls back to splash instead of crashing with
      // "Null check operator used on a null value" in PageRedirect.
      unknownRoute: AppPages.pages.firstWhere(
        (GetPage<dynamic> p) => p.name == AppRoutes.splash,
      ),
    );
  }
}

void testPrintLS(String text) {
  DateTime dateTime = DateTime.now();
  final formattedTime =
      '${DateFormat('HH:mm:ss').format(dateTime)}.${dateTime.millisecond.toString().padLeft(3, '0')}';

  debugPrint('[$formattedTime]#### $text');

  if (Get.isRegistered<TestLogsScreenController>()) {
    Get.find<TestLogsScreenController>().addMessage(text, ts: dateTime);
  }
}
