import 'package:flutter/material.dart';
import 'package:pow_wow/widgets/avatar_placeholder.dart';
import 'package:pow_wow/widgets/cached_avatar_image.dart';

import '../../../../app/data/enums/tribe_member_status.dart';
import '../../../../app/data/models/tribe_member.dart';

class FamilyScreenAvatar extends StatelessWidget {
  final TribeMember member;

  const FamilyScreenAvatar({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    const size = 64.0;
    return Stack(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.transparent,
            border: Border.all(color: member.status.largeCircleColor, width: 3),
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
              color: member.status.smallCircleColor,
              border: Border.all(color: Colors.white, width: 2),
            ),
            width: 20,
            height: 20,
          ),
        ),
      ],
    );
  }
}
