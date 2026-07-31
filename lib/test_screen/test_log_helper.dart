enum DiagnosticLogKind {
  ui('UI'),
  flow('FLOW'),
  warn('WARN'),
  err('ERR');

  const DiagnosticLogKind(this.label);

  final String label;
}

class DiagnosticLog {
  static const int _maxValueLength = 80;
  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static final RegExp _sensitiveKeyRegex = RegExp(
    r'(token|secret|password|authorization|auth|bearer|payload)',
    caseSensitive: false,
  );

  static String ui(
    String scope,
    String event, {
    Map<String, Object?> data = const {},
  }) {
    return build(
      kind: DiagnosticLogKind.ui,
      scope: scope,
      event: event,
      data: data,
    );
  }

  static String flow(
    String scope,
    String event, {
    Map<String, Object?> data = const {},
  }) {
    return build(
      kind: DiagnosticLogKind.flow,
      scope: scope,
      event: event,
      data: data,
    );
  }

  static String warn(
    String scope,
    String event, {
    Map<String, Object?> data = const {},
  }) {
    return build(
      kind: DiagnosticLogKind.warn,
      scope: scope,
      event: event,
      data: data,
    );
  }

  static String err(
    String scope,
    String event, {
    Map<String, Object?> data = const {},
  }) {
    return build(
      kind: DiagnosticLogKind.err,
      scope: scope,
      event: event,
      data: data,
    );
  }

  static String build({
    required DiagnosticLogKind kind,
    required String scope,
    required String event,
    Map<String, Object?> data = const {},
  }) {
    final safeScope = _normalize(scope);
    final safeEvent = _normalize(event);
    final fields = <String>[];

    data.forEach((String key, Object? value) {
      if (value == null || _sensitiveKeyRegex.hasMatch(key)) {
        return;
      }

      final normalizedValue = _normalize(value.toString());
      if (normalizedValue.isEmpty) {
        return;
      }

      final safeValue = normalizedValue.length > _maxValueLength
          ? '${normalizedValue.substring(0, _maxValueLength - 3)}...'
          : normalizedValue;
      fields.add('$key=$safeValue');
    });

    if (fields.isEmpty) {
      return '${kind.label}::$safeScope::$safeEvent';
    }

    return '${kind.label}::$safeScope::$safeEvent | ${fields.join(', ')}';
  }

  static String _normalize(String value) {
    return value.replaceAll(_whitespaceRegex, ' ').trim();
  }
}
