import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/onboarding_storage.dart';
import '../../app/theme.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.completionStore, this.onFinished});

  final OnboardingCompletionStore? completionStore;
  final Future<void> Function()? onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _pageCount = 3;

  final PageController _pageController = PageController();
  int _pageIndex = 0;
  bool _isFinishing = false;

  OnboardingCompletionStore get _completionStore =>
      widget.completionStore ?? OnboardingStorage();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _showNextPage() async {
    if (_pageIndex == _pageCount - 1) {
      await _finishOnboarding();
      return;
    }

    await _pageController.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;

    setState(() {
      _isFinishing = true;
    });

    await _completionStore.markCompleted();
    if (!mounted) return;

    final Future<void> Function()? onFinished = widget.onFinished;
    if (onFinished != null) {
      await onFinished();
      if (mounted) {
        setState(() {
          _isFinishing = false;
        });
      }
      return;
    }

    Get.offAllNamed(AppRoutes.splash);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.whiteBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: _pageIndex < _pageCount - 1
                          ? TextButton(
                              key: const ValueKey<String>(
                                'onboarding_skip_button',
                              ),
                              onPressed: _isFinishing
                                  ? null
                                  : _finishOnboarding,
                              child: Text(
                                'Skip',
                                style: AppTextStyle.mainSemibold.copyWith(
                                  color: AppColors.greenText,
                                  fontSize: 16,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey<String>('onboarding_skip_space'),
                            ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView(
                  key: const ValueKey<String>('onboarding_page_view'),
                  controller: _pageController,
                  onPageChanged: (int index) {
                    setState(() {
                      _pageIndex = index;
                    });
                  },
                  children: const <Widget>[
                    _OnboardingPage(
                      title: 'Stay close\nto your tribe',
                      body: 'PowWow keeps family just\none press away.',
                      illustration: _AssetIllustration(
                        assetPath: 'assets/png/onboarding_family.png',
                      ),
                    ),
                    _OnboardingPage(
                      title: 'Invite your\npeople',
                      body: 'Add family and friends to\nyour private tribe.',
                      illustration: _AssetIllustration(
                        assetPath: 'assets/png/onboarding_invite.png',
                      ),
                    ),
                    _OnboardingPage(
                      title: 'Press. Talk. Release.',
                      body: 'Hold the coral button while\nyou speak.',
                      illustration: _PushToTalkIllustration(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _PageIndicator(pageIndex: _pageIndex, pageCount: _pageCount),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 62,
                  child: ElevatedButton(
                    key: const ValueKey<String>('onboarding_primary_button'),
                    onPressed: _isFinishing ? null : _showNextPage,
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      backgroundColor: AppColors.orangeBg,
                      foregroundColor: AppColors.whiteText,
                      disabledBackgroundColor: AppColors.orangeBg.withValues(
                        alpha: 0.55,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isFinishing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppColors.whiteText,
                            ),
                          )
                        : Text(
                            _pageIndex == _pageCount - 1
                                ? 'Start PowWow'
                                : 'Continue',
                            style: AppTextStyle.mainBold.copyWith(
                              color: AppColors.whiteText,
                              fontSize: 19,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.title,
    required this.body,
    required this.illustration,
  });

  final String title;
  final String body;
  final Widget illustration;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxHeight < 570;
          final double titleSize = compact ? 30 : 36;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(height: compact ? 4 : 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: AppTextStyle.mainBold.copyWith(
                  color: AppColors.blackText,
                  fontSize: titleSize,
                  fontWeight: FontWeight.w800,
                  height: 1.08,
                ),
              ),
              SizedBox(height: compact ? 10 : 14),
              Text(
                body,
                textAlign: TextAlign.center,
                style: AppTextStyle.mainRegular.copyWith(
                  color: AppColors.blackText3,
                  fontSize: compact ? 16 : 18,
                  height: 1.35,
                ),
              ),
              SizedBox(height: compact ? 8 : 14),
              Expanded(child: Center(child: illustration)),
            ],
          );
        },
      ),
    );
  }
}

class _AssetIllustration extends StatelessWidget {
  const _AssetIllustration({required this.assetPath});

  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440, maxHeight: 410),
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

class _PushToTalkIllustration extends StatelessWidget {
  const _PushToTalkIllustration();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double diameter = min(
          290.0,
          min(constraints.maxWidth * 0.78, constraints.maxHeight * 0.9),
        );
        final double scale = diameter / 290;

        return Container(
          width: diameter,
          height: diameter,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFFF05E49), Color(0xFFF06D53)],
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                Icons.mic_rounded,
                color: AppColors.whiteText,
                size: 104 * scale,
              ),
              SizedBox(height: 12 * scale),
              Text(
                'HOLD TO SPEAK',
                style: AppTextStyle.mainSemibold.copyWith(
                  color: AppColors.whiteText,
                  fontSize: 15 * scale,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PageIndicator extends StatelessWidget {
  const _PageIndicator({required this.pageIndex, required this.pageCount});

  final int pageIndex;
  final int pageCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List<Widget>.generate(pageCount, (int index) {
        final bool isActive = index == pageIndex;
        return AnimatedContainer(
          key: ValueKey<String>('onboarding_page_dot_$index'),
          duration: const Duration(milliseconds: 180),
          width: isActive ? 10 : 8,
          height: isActive ? 10 : 8,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? AppColors.greenText : const Color(0xFFE3DED2),
          ),
        );
      }),
    );
  }
}
