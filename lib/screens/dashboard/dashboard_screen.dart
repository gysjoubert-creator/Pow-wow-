import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';

import '../../app/theme.dart';
import '../tabs/family/family_screen.dart';
import '../tabs/home/home_screen.dart';
import 'dashboard_controller.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<DashboardController>(
      builder: (controller) {
        return Scaffold(
          backgroundColor: AppColors.greyBg,
          body: controller.canShowDashboard
              ? _buildContentView(controller)
              : const Center(child: CircularProgressIndicator()),
          bottomNavigationBar: controller.canShowDashboard
              ? _buildBottomNavigationBar(controller)
              : null,
        );
      },
    );
  }

  Widget _buildContentView(DashboardController controller) {
    return IndexedStack(
      index: controller.tabIndex,
      children: [
        controller.visitedTabs.contains(0)
            ? const HomeScreen()
            : const SizedBox.shrink(),
        controller.visitedTabs.contains(1)
            ? const FamilyScreen()
            : const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildTabIcon({
    required String icon,
    required double iconWidht,
    required bool isActive,
  }) {
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isActive
            ? AppColors.greenText.withValues(alpha: 0.1)
            : Colors.transparent,
      ),
      width: 48,
      height: 32,
      child: SvgPicture.asset(
        icon,
        fit: BoxFit.contain,
        width: iconWidht,
        colorFilter: ColorFilter.mode(
          isActive ? AppColors.greenText : AppColors.greyText2,
          BlendMode.srcIn,
        ),
      ),
    );
  }

  Widget _buildBottomNavigationBar(DashboardController controller) {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      selectedItemColor: AppColors.greenText,
      unselectedItemColor: AppColors.greyText2,
      selectedLabelStyle: AppTextStyle.mainBold.copyWith(fontSize: 10),
      unselectedLabelStyle: AppTextStyle.mainBold.copyWith(fontSize: 10),
      currentIndex: controller.tabIndex,
      onTap: controller.changeTabIndex,
      items: [
        BottomNavigationBarItem(
          icon: _buildTabIcon(
            icon: 'assets/svg/tab_home.svg',
            iconWidht: 18,
            isActive: false,
          ),
          activeIcon: _buildTabIcon(
            icon: 'assets/svg/tab_home.svg',
            iconWidht: 18,
            isActive: true,
          ),
          label: 'HOME',
        ),
        BottomNavigationBarItem(
          icon: _buildTabIcon(
            icon: 'assets/svg/tab_family.svg',
            iconWidht: 25,
            isActive: false,
          ),
          activeIcon: _buildTabIcon(
            icon: 'assets/svg/tab_family.svg',
            iconWidht: 25,
            isActive: true,
          ),
          label: 'FAMILY',
        ),
      ],
    );
  }
}
