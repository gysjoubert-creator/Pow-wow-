# Рефакторинг: CallStateService

> Документ описывает план замены 6 глобальных флагов call flow в `main.dart`
> на единый `CallStateService` с явной машиной состояний.
>
> **Когда делать:** отдельная ветка, клиент предупреждён о возможной регрессии,
> оба устройства (iOS + Android) доступны для ручного тестирования.
> Ориентировочные трудозатраты: ~1.5 рабочих дня.

---

## Текущее состояние (проблема)

В `lib/main.dart` живут 6 глобальных мутабельных переменных, которые вместе
образуют неявную машину состояний вызова:

```dart
bool pendingCallAccept = false;
String? pendingAcceptedCallId;
bool pendingAcceptedCallEnableMic = false;
bool incomingCallRinging = false;
bool iosCallkitAudioSessionActive = false;
bool iosDeclinedIncomingCallBeforeForeground = false;
```

**Почему это проблема:**
- Читаются и пишутся из `main.dart`, `HomeController`, `LiveKitController`
  без синхронизации.
- Нет валидации переходов — любой флаг можно поставить в любой момент.
- `unawaited()` вызовы создают гонки при одновременном изменении нескольких
  флагов.
- Добавление нового сценария (например, "declined before foreground") требует
  нового флага и проверок во всех файлах.
- При аварийном завершении флаги могут застрять в неправильном состоянии.

---

## Целевое состояние

### Enum `CallFlowState`

```dart
// lib/app/services/call_state_service.dart

enum CallFlowState {
  /// Нет активного звонка, приложение в обычном режиме.
  idle,

  /// Входящий звонок рингует (CallKit UI показан, пользователь ещё не ответил).
  ringing,

  /// Пользователь принял звонок, LiveKit ещё не подключён.
  accepting,

  /// LiveKit подключён, идёт разговор.
  connected,

  /// Пользователь отклонил звонок до выхода на передний план (iOS cold start).
  declinedBeforeForeground,
}
```

### `CallStateService`

```dart
class CallStateService extends GetxService {
  final _state = CallFlowState.idle.obs;
  CallFlowState get state => _state.value;

  String? pendingAcceptedCallId;
  bool pendingAcceptedCallEnableMic = false;
  bool iosCallkitAudioSessionActive = false;

  bool get isRinging         => _state.value == CallFlowState.ringing;
  bool get isPendingAccept   => _state.value == CallFlowState.accepting;
  bool get isConnected       => _state.value == CallFlowState.connected;
  bool get isDeclinedBeforeFG =>
      _state.value == CallFlowState.declinedBeforeForeground;

  void onCallIncoming() {
    _transition(to: CallFlowState.ringing, from: 'incoming');
  }

  void onCallAccepted({required String? callId, required bool enableMic}) {
    pendingAcceptedCallId = callId;
    pendingAcceptedCallEnableMic = enableMic;
    _transition(to: CallFlowState.accepting, from: 'accepted');
  }

  void onCallConnected() {
    _transition(to: CallFlowState.connected, from: 'livekit_connected');
  }

  void onCallDeclined({required bool appIsForegrounded}) {
    pendingAcceptedCallId = null;
    pendingAcceptedCallEnableMic = false;
    iosCallkitAudioSessionActive = false;

    if (!appIsForegrounded && GetPlatform.isIOS) {
      _transition(to: CallFlowState.declinedBeforeForeground, from: 'declined');
    } else {
      _transition(to: CallFlowState.idle, from: 'declined');
    }
  }

  void onForegroundRestored() {
    if (_state.value == CallFlowState.declinedBeforeForeground) {
      _transition(to: CallFlowState.idle, from: 'foreground_restored');
    }
  }

  void onAcceptConsumed() {
    if (_state.value == CallFlowState.accepting) {
      pendingAcceptedCallId = null;
      _transition(to: CallFlowState.idle, from: 'accept_consumed');
    }
  }

  void reset() {
    pendingAcceptedCallId = null;
    pendingAcceptedCallEnableMic = false;
    iosCallkitAudioSessionActive = false;
    _transition(to: CallFlowState.idle, from: 'reset');
  }

  void _transition({required CallFlowState to, required String from}) {
    final prev = _state.value;
    if (prev == to) return;
    testPrintLS(
      DiagnosticLog.flow(
        'CallStateService',
        'state_changed',
        data: {'from': prev.name, 'to': to.name, 'source': from},
      ),
    );
    _state.value = to;
  }
}
```

---

## План миграции (пошаговый)

### Фаза 1 — Добавить сервис, не удаляя старые флаги (безопасно)

1. Создать `lib/app/services/call_state_service.dart`.
2. Зарегистрировать в `main()`:
   ```dart
   Get.put<CallStateService>(CallStateService(), permanent: true);
   ```
3. Старые переменные **не трогать**.

**Проверка:** приложение собирается и работает как раньше.

---

### Фаза 2 — Мигрировать `main.dart`

Заменить каждое присвоение флага на вызов метода сервиса:

| Было | Стало |
|---|---|
| `incomingCallRinging = true` | `callState.onCallIncoming()` |
| `incomingCallRinging = false` (accepted) | `callState.onCallAccepted(...)` |
| `incomingCallRinging = false` (declined) | `callState.onCallDeclined(...)` |
| `iosDeclinedIncomingCallBeforeForeground = false` (on resume) | `callState.onForegroundRestored()` |
| `pendingCallAccept = true` + `pendingAcceptedCallId = ...` | `callState.onCallAccepted(...)` |
| `pendingCallAccept = false` | `callState.onAcceptConsumed()` |
| `iosCallkitAudioSessionActive = isActivate` | `callState.iosCallkitAudioSessionActive = isActivate` |

Удалить старые глобальные переменные **только после** того как все чтения заменены.

**Проверка:** базовый сценарий — incoming call → accept → connected → end.

---

### Фаза 3 — Мигрировать `HomeController`

Заменить чтение флагов:

| Было | Стало |
|---|---|
| `if (pendingCallAccept)` | `if (callState.isPendingAccept)` |
| `incomingCallRinging` | `callState.isRinging` |
| `pendingAcceptedCallEnableMic` | `callState.pendingAcceptedCallEnableMic` |
| `iosDeclinedIncomingCallBeforeForeground` | `callState.isDeclinedBeforeFG` |

Дополнительно: убрать дублирующий запрос permissions.
Оставить только `_ensurePermissions()` в `_initAsync()`,
удалить отдельный `_checkBluetoothPermissions()` из `onInit()`.

**Проверка:** весь call flow на обеих платформах.

---

### Фаза 4 — Мигрировать `LiveKitController`

Заменить прямые чтения `iosCallkitAudioSessionActive` и
`iosDeclinedIncomingCallBeforeForeground` на `Get.find<CallStateService>()`.

---

## Файлы которые затрагивает рефакторинг

| Файл | Изменения |
|---|---|
| `lib/app/services/call_state_service.dart` | **Новый файл** |
| `lib/main.dart` | Удалить 6 глобальных переменных, заменить на вызовы сервиса |
| `lib/screens/tabs/home/home_controller.dart` | Читать состояние из сервиса, убрать дублирующий запрос permissions |
| `lib/screens/tabs/home/live_kit_controller.dart` | Читать `iosCallkitAudioSessionActive` из сервиса |

---

## Чеклист ручного тестирования после рефакторинга

### iOS
- [ ] Входящий звонок → **принять** (приложение на экране)
- [ ] Входящий звонок → **принять** (приложение в фоне)
- [ ] Входящий звонок → **принять** (приложение убито, cold start)
- [ ] Входящий звонок → **отклонить** (приложение на экране)
- [ ] Входящий звонок → **отклонить** (приложение убито, до выхода на передний план)
- [ ] Принять → открыть приложение → микрофон в правильном состоянии
- [ ] Кнопка Mute на CallKit UI → состояние микрофона синхронизировано
- [ ] Kill app во время звонка → перезапуск → состояние `idle`

### Android
- [ ] Входящий FCM звонок → **принять** (приложение на экране)
- [ ] Входящий FCM звонок → **принять** (приложение убито)
- [ ] Входящий FCM звонок → **отклонить**
- [ ] После принятия: нет дублирующего `isRunningService`
- [ ] После принятия: нет ошибки "permission request already running"

### Общее
- [ ] Два устройства (iOS + Android) в одном tribe — оба слышат друг друга
- [ ] Потеря сети во время звонка → recovery → переподключение
- [ ] Логи показывают `FLOW::CallStateService::state_changed` при каждом
      переходе с корректными `from` / `to`

---

## Оценка трудозатрат

| Этап | Время |
|---|---|
| Фаза 1 — создать сервис | ~1 ч |
| Фаза 2 — main.dart | ~2 ч |
| Фаза 3 — HomeController | ~2–3 ч |
| Фаза 4 — LiveKitController | ~1 ч |
| Ручное тестирование + правки | ~4–6 ч |
| **Итого** | **~1.5 рабочих дня** |
