import 'package:get/get.dart';
import 'tribe_settings_controller.dart';

class TribeSettingsBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<TribeSettingsController>(() => TribeSettingsController());
  }
}
