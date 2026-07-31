import 'package:flutter/material.dart';
import 'package:pow_wow/widgets/avatar_placeholder.dart';
import 'package:pow_wow/widgets/cached_avatar_image.dart';

import '../../../../app/theme.dart';
import '../../../../app/data/models/tribe_member.dart';

class HomeScreenAvatar extends StatelessWidget {
  final TribeMember member;

  const HomeScreenAvatar({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    final largeCircleColor = member.status == .silent
        ? Colors.transparent
        : AppColors.greenText;
    final smallCircleColor = member.status == .silent
        ? AppColors.greyBg4
        : AppColors.greenBg2;
    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.transparent,
            border: Border.all(color: largeCircleColor, width: 2),
          ),
          padding: EdgeInsets.all(2),
          child: ClipOval(
            child: member.avatarUrl != null
                ? CachedAvatarImage(url: member.avatarUrl!, size: size)
                : AvatarPlaceholder(),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              color: smallCircleColor,
            ),
            width: 20,
            height: 20,
          ),
        ),
      ],
    );
  }
}
