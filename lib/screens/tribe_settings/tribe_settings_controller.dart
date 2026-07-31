import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart' as pi;
import '../../app/data/models/user_profile.dart';
import '../../app/services/firebase/auth_service.dart';
import '../../app/settings_storage.dart';
import '../../app/utils/screen_helper.dart';
import '../../main.dart';
import '../../test_screen/test_log_helper.dart';
import '../tabs/home/home_controller.dart';

class TribeSettingsController extends GetxController {
  final AuthService _authService = Get.find<AuthService>();

  UserProfile get myProfile => _authService.myProfile!;

  bool _isLoading = false;

  bool _isLeavingTribe = false;
  bool get isLeavingTribe => _isLeavingTribe;

  bool get canLeaveTribe {
    if (Get.isRegistered<HomeController>()) {
      return Get.find<HomeController>().canLeaveTribe;
    }
    return false;
  }

  bool _isHeadphonePriority = false;
  bool get isHeadphonePriority => _isHeadphonePriority;

  bool _isBedtimeDND = false;
  bool get isBedtimeDND => _isBedtimeDND;
  double _intercomVolume = 1.0;
  double get intercomVolume => _intercomVolume;
  String _appVersionTitle = '';
  String get appVersionTitle => _appVersionTitle;

  String? tribeId;

  @override
  void onInit() {
    super.onInit();
    tribeId = _authService.myProfile?.tribeId;
    _setAppVersionTitle();
    _loadSettings();
  }

  @override
  void onClose() {
    SettingsStorage.setIntercomVolume(_intercomVolume);
    SettingsStorage.setHeadphonePriority(_isHeadphonePriority);
    SettingsStorage.setBedtimeDnd(_isBedtimeDND);
    super.onClose();
  }

  Future<void> _loadSettings() async {
    _isLoading = true;
    _isHeadphonePriority = await SettingsStorage.getHeadphonePriority();
    _isBedtimeDND = await SettingsStorage.getBedtimeDnd();
    _intercomVolume = await SettingsStorage.getIntercomVolume();

    _isLoading = false;
    testPrintLS(
      DiagnosticLog.flow(
        'TribeSettingsController',
        'settings_loaded',
        data: {
          'headphonePriority': _isHeadphonePriority,
          'bedtimeDnd': _isBedtimeDND,
          'volume': _intercomVolume.toStringAsFixed(2),
        },
      ),
    );
    update();
  }

  Future<void> setHeadphonePriority(bool value) async {
    if (_isLoading) {
      testPrintLS(
        DiagnosticLog.warn(
          'TribeSettingsController',
          'headphone_priority_ignored_loading',
        ),
      );
      return;
    }

    _isHeadphonePriority = value;
    update();

    _isLoading = true;
    await SettingsStorage.setHeadphonePriority(value);
    _isLoading = false;
    testPrintLS(
      DiagnosticLog.flow(
        'TribeSettingsController',
        'headphone_priority_changed',
        data: {'value': value},
      ),
    );
  }

  Future<void> setBedtimeDND(bool value) async {
    if (_isLoading) {
      testPrintLS(
        DiagnosticLog.warn(
          'TribeSettingsController',
          'bedtime_dnd_ignored_loading',
        ),
      );
      return;
    }

    _isBedtimeDND = value;
    update();

    _isLoading = true;
    await SettingsStorage.setBedtimeDnd(value);
    _isLoading = false;
    testPrintLS(
      DiagnosticLog.flow(
        'TribeSettingsController',
        'bedtime_dnd_changed',
        data: {'value': value},
      ),
    );
  }

  Future<void> setVolume(double value) async {
    if (_isLoading) return;

    final double nextVolume = value.clamp(0.0, 1.0);
    _intercomVolume = nextVolume;
    update();

    final liveKitController = Get.isRegistered<HomeController>()
        ? Get.find<HomeController>().liveKitController
        : null;
    await liveKitController?.setIntercomVolume(nextVolume);
    await SettingsStorage.setIntercomVolume(nextVolume);
  }

  Future<void> leaveTribe() async {
    if (_isLeavingTribe || !canLeaveTribe) {
      return;
    }

    if (!Get.isRegistered<HomeController>()) {
      testPrintLS(
        DiagnosticLog.warn(
          'TribeSettingsController',
          'leave_tribe_home_controller_missing',
        ),
      );
      ScreenHelper.showErrorSnackbar('Could not leave the tribe. Please try again.');
      return;
    }

    _isLeavingTribe = true;
    update();

    testPrintLS(
      DiagnosticLog.flow(
        'TribeSettingsController',
        'leave_tribe_started',
        data: {
          'tribeId': myProfile.tribeId,
          'uid': myProfile.uid,
        },
      ),
    );

    try {
      await Get.find<HomeController>().leaveTribe();
      testPrintLS(
        DiagnosticLog.flow('TribeSettingsController', 'leave_tribe_succeeded'),
      );
    } catch (error) {
      testPrintLS(
        DiagnosticLog.err(
          'TribeSettingsController',
          'leave_tribe_failed',
          data: {'error': error.toString()},
        ),
      );
      ScreenHelper.showGenericErrorSnackbar(error);
    } finally {
      _isLeavingTribe = false;
      update();
    }
  }

  Future<void> _setAppVersionTitle() async {
    final pi.PackageInfo packageInfo = await pi.PackageInfo.fromPlatform();
    _appVersionTitle =
        'VERSION ${packageInfo.version} (BUILD ${packageInfo.buildNumber})';
  }
}
