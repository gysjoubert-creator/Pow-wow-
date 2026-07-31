class TribeMessage {
  final String id;
  final String senderName;
  final String text;
  final DateTime createdAt;

  const TribeMessage({
    required this.id,
    required this.senderName,
    required this.text,
    required this.createdAt,
  });
}
