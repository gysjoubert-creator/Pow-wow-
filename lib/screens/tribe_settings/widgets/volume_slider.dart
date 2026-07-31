import 'package:flutter/material.dart';

import '../../../app/theme.dart';

class VolumeSlider extends StatefulWidget {
  const VolumeSlider({
    super.key,
    this.initialValue = 1.0,
    this.onChanged,
    this.onChangeEnd,
  });

  final double initialValue;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<VolumeSlider> createState() => _VolumeSliderState();
}

class _VolumeSliderState extends State<VolumeSlider> {
  double _value = 1.0;

  @override
  void initState() {
    super.initState();
    _value = widget.initialValue.clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant VolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.initialValue == widget.initialValue) {
      return;
    }

    final double nextValue = widget.initialValue.clamp(0.0, 1.0);
    if (nextValue == _value) {
      return;
    }

    setState(() {
      _value = nextValue;
    });
  }

  void _updateValue(Offset localPosition, double maxWidth) {
    if (maxWidth <= 0) {
      return;
    }

    double newValue = localPosition.dx / maxWidth;
    newValue = newValue.clamp(0.0, 1.0);
    newValue = (newValue * 100).round() / 100;

    if (newValue == _value) {
      return;
    }

    setState(() {
      _value = newValue;
    });

    widget.onChanged?.call(_value);
  }

  void _notifyChangeEnd() {
    widget.onChangeEnd?.call(_value);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxWidth = constraints.maxWidth;
        final double fillWidth = maxWidth * _value;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            _updateValue(details.localPosition, maxWidth);
          },
          onTapUp: (_) => _notifyChangeEnd(),
          onHorizontalDragUpdate: (DragUpdateDetails details) {
            _updateValue(details.localPosition, maxWidth);
          },
          onHorizontalDragEnd: (_) => _notifyChangeEnd(),
          onHorizontalDragCancel: _notifyChangeEnd,
          child: Container(
            width: double.infinity,
            height: 24,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: AppColors.greyBg2,
            ),
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 16,
                    width: fillWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: AppColors.tealBg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
