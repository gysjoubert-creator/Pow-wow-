import 'package:pow_wow/screens/create_profile/create_profile_screen.dart';
import 'package:pow_wow/screens/edit_profile/edit_profile_screen.dart';
import 'package:pow_wow/screens/onboarding/onboarding_screen.dart';
import 'package:pow_wow/screens/splash/splash_screen.dart';
import 'package:pow_wow/screens/subscription/subscription_binding.dart';
import 'package:pow_wow/screens/subscription/subscription_screen.dart';
import 'package:get/get.dart';

// import '../../screens/calling/calling_binding.dart';
// import '../../screens/calling/calling_screen.dart';
import '../../../screens/dashboard/dashboard_binding.dart';
import '../../../screens/dashboard/dashboard_screen.dart';
import '../../../screens/tribe_settings/tribe_settings_binding.dart';
import '../../../screens/tribe_settings/tribe_settings_screen.dart';
import 'app_routes.dart';

class AppPages {
  static final List<GetPage<dynamic>> pages = <GetPage<dynamic>>[
    GetPage<OnboardingScreen>(
      name: AppRoutes.onboarding,
      page: () => const OnboardingScreen(),
    ),

    GetPage<DashboardScreen>(
      name: AppRoutes.splash,
      page: () => const SplashScreen(),
    ),

    GetPage<DashboardScreen>(
      name: AppRoutes.createProfile,
      page: () => const CreateProfileScreen(),
    ),

    GetPage<EditProfileScreen>(
      name: AppRoutes.editProfile,
      page: () => const EditProfileScreen(),
    ),

    GetPage<DashboardScreen>(
      name: AppRoutes.dashboard,
      page: () => const DashboardScreen(),
      binding: DashboardBinding(),
    ),

    GetPage<TribeSettingsScreen>(
      name: AppRoutes.tribeSettings,
      page: () => const TribeSettingsScreen(),
      binding: TribeSettingsBinding(),
    ),

    GetPage<SubscriptionScreen>(
      name: AppRoutes.subscription,
      page: () => const SubscriptionScreen(),
      binding: SubscriptionBinding(),
    ),

    // GetPage<CallingScreen>( //td //check
    //   name: AppRoutes.calling,
    //   page: () => const CallingScreen(),
    //   binding: CallingBinding(),
    // ),
  ];
}
