import '../enums/tribe_member_status.dart';

class TribeMember {
  final String id;
  final String name;
  final String? avatarUrl;
  final CallMemberStatus status;

  const TribeMember({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.status,
  });
}
