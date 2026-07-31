import 'package:flutter/widgets.dart';

import '../../theme.dart';

enum CallMemberStatus { atHome, listening, silent }

extension CallMemberStatusExtension on CallMemberStatus {
  String get title => switch (this) {
    .atHome => 'At Home',
    .listening => 'Listening',
    .silent => 'Silent',
  };

  Color get titleColor => switch (this) {
    .atHome => AppColors.greenBg,
    .listening => AppColors.orangeBg3,
    .silent => AppColors.greyText2,
  };

  Color get largeCircleColor => switch (this) {
    .atHome => AppColors.greenBg,
    .listening => AppColors.orangeBg3,
    .silent => AppColors.violetBg,
  };

  Color get smallCircleColor => switch (this) {
    .atHome => AppColors.greenBg,
    .listening => AppColors.greenBg,
    .silent => AppColors.greyBg4,
  };
}
