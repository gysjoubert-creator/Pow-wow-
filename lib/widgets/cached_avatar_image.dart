import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:pow_wow/widgets/avatar_placeholder.dart';

class CachedAvatarImage extends StatelessWidget {
  final String url;
  final double size;

  const CachedAvatarImage({
    super.key,
    required this.url,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final int cacheSize = (size * MediaQuery.devicePixelRatioOf(context))
        .round();

    return CachedNetworkImage(
      key: ValueKey(url),
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: cacheSize,
      memCacheHeight: cacheSize,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, _) => const AvatarPlaceholder(),
      errorWidget: (_, _, _) => const AvatarPlaceholder(),
    );
  }
}
