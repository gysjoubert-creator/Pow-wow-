import 'user_profile.dart';

class TribeMembersSnapshot {
  final List<UserProfile> profiles;
  final bool isFromCache;

  const TribeMembersSnapshot({
    required this.profiles,
    required this.isFromCache,
  });
}
