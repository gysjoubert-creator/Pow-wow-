import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../../../app/theme.dart';

class HoldToSpeakButton extends StatefulWidget {
  const HoldToSpeakButton({
    super.key,
    this.onPressed,
    this.onReleased,
    this.size = 320,
  });

  final VoidCallback? onPressed;
  final VoidCallback? onReleased;
  final double size;

  @override
  State<HoldToSpeakButton> createState() => _HoldToSpeakButtonState();
}

class _HoldToSpeakButtonState extends State<HoldToSpeakButton>
    with SingleTickerProviderStateMixin {
  static const double _mainCircleSize = 256;

  late final AnimationController _pulseController;
  bool _isHolding = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
  }

  @override
  void deactivate() {
    _stopHolding();
    super.deactivate();
  }

  @override
  void dispose() {
    _stopHolding();
    _pulseController.dispose();
    super.dispose();
  }

  void _startHolding() {
    if (_isHolding) return;

    setState(() {
      _isHolding = true;
    });

    _pulseController.repeat();
    widget.onPressed?.call();
  }

  void _stopHolding() {
    if (!_isHolding) return;

    setState(() {
      _isHolding = false;
    });

    _pulseController.stop();
    _pulseController.reset();
    widget.onReleased?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _startHolding(),
      onPointerUp: (_) => _stopHolding(),
      onPointerCancel: (_) => _stopHolding(),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isHolding) ...[
              _AnimatedPulseCircle(
                controller: _pulseController,
                delay: 0.0,
                maxScale: 1.35,
                color: AppColors.orangeBg,
                strokeOpacity: 0.24,
                strokeWidth: 3,
                baseSize: _mainCircleSize,
              ),
              _AnimatedPulseCircle(
                controller: _pulseController,
                delay: 0.33,
                maxScale: 1.55,
                color: AppColors.orangeBg,
                strokeOpacity: 0.16,
                strokeWidth: 2,
                baseSize: _mainCircleSize,
              ),
            ],
            _MainButton(isHolding: _isHolding, size: _mainCircleSize),
          ],
        ),
      ),
    );
  }
}

class _MainButton extends StatelessWidget {
  const _MainButton({required this.isHolding, required this.size});

  final bool isHolding;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isHolding ? 0.97 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.orangeBg,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
            width: 4,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.orangeBg.withValues(
                alpha: isHolding ? 0.18 : 0.10,
              ),
              blurRadius: isHolding ? 24 : 12,
              spreadRadius: isHolding ? 6 : 2,
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SvgPicture.asset(
              'assets/svg/mic.svg',
              fit: BoxFit.contain,
              height: 57,
            ),
            const SizedBox(height: 10),
            Text(
              'Call the Tribe',
              style: AppTextStyle.mainBold.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: AppColors.whiteText,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'HOLD TO SPEAK',
              style: AppTextStyle.mainBold.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: AppColors.whiteText.withValues(alpha: 0.7),
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedPulseCircle extends StatelessWidget {
  const _AnimatedPulseCircle({
    required this.controller,
    required this.delay,
    required this.maxScale,
    required this.color,
    required this.strokeOpacity,
    required this.strokeWidth,
    required this.baseSize,
  });

  final AnimationController controller;
  final double delay;
  final double maxScale;
  final Color color;
  final double strokeOpacity;
  final double strokeWidth;
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final double progress = (controller.value + delay) % 1.0;
        final double scale = 1.0 + (maxScale - 1.0) * progress;
        final double opacity = (0.35 + (1.0 - progress) * 0.65) * strokeOpacity;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: baseSize,
            height: baseSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: color.withValues(alpha: opacity.clamp(0.0, 1.0)),
                width: strokeWidth,
              ),
            ),
          ),
        );
      },
    );
  }
}
