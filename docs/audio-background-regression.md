# Audio & background regression checklist

Ручной чеклист для проверок после правок в audio / LiveKit / CallKit / background white noise.

Архитектурный снимок поведения — в [`current-state.md`](current-state.md).  
Этот документ — **что именно прогнать на устройстве**, чтобы не сломать уже исправленные сценарии.

## Когда прогонять

- Любые изменения в:
  - `lib/screens/tabs/home/live_kit_controller.dart`
  - `lib/app/services/background_white_noise_service.dart`
  - `lib/screens/tabs/home/home_controller.dart` (lifecycle, auto-connect, call flow)
  - `lib/main.dart` (глобальные call-флаги, lifecycle)
  - `lib/app/utils/callkit_state_helper.dart`
  - iOS `Info.plist` / audio session на нативной стороне
- Перед merge PR, который трогает audio в фоне.

Минимум на CI: `flutter test` (в т.ч. `test/background_white_noise_service_test.dart`).  
Это **не заменяет** прогон на реальном iPhone.

## Как проверять

1. Собрать debug на **физическом iPhone** (симулятор для suspend/timer ведёт себя иначе).
2. Открыть tribe room, дождаться `LiveKit CONNECTED`.
3. Включить логи: **Home → Test logs** (или экран логов из меню).
4. После сценария скопировать строки с префиксом `FLOW::LiveKitController::background_white_noise_`.
5. Отметить в таблице ниже: ✅ / ❌ + дата + модель устройства.

### Ключевые поля в логах

Искать событие `background_white_noise_synced`:

| Поле | Ожидание в фоне |
|------|-----------------|
| `isAppInForeground` | `false` |
| `hasRemoteSpeaker` | любое — не влияет на воспроизведение |
| `localMicEnabled` | `false` |
| `isSuppressed` | `false` |
| `isPlaying` | **`true`** |
| `playbackActive` | **`true`** |
| `watchdogActive` | `true` в iOS listen-only фоне |

> `hasRemoteSpeaker` поле логируется для диагностики, но **не** является условием воспроизведения белого шума начиная с фикса BG-04 (2026-05-27).

Дополнительно при старте/остановке шума:

- `ios_audio_session_configured` с `source=background_white_noise_playback_changed`
- при ошибке: `background_white_noise_failed`

### Важно: шум почти неслышимый

Громкость задаётся `kBackgroundWhiteNoiseVolume` (`0.0005`) в `background_white_noise_service.dart`.  
Цель — **держать `AVAudioSession`**, а не «шипение» для пользователя.  
Проверять по **`isPlaying=true` в логах**, а не на слух.

## Условия включения белого шума (справка)

Координатор `BackgroundWhiteNoiseCoordinator` играет в фоне, когда одновременно:

- приложение **не** в `resumed`;
- локальный микрофон выключен;
- не подавлено CallKit / incoming flow (`isSuppressed=false`).

> **Важно:** `hasRemoteSpeaker` **намеренно исключён** из условий. Шум продолжает играть в фоне даже когда удалённый участник говорит. Громкость 0.0005 абсолютно неслышима, но удерживает `AVAudioSession` и Dart VM активными. Остановка шума во время удалённой речи приводила к заморозке Dart VM iOS-ом, блокируя очередь координатора до следующего OS-wake события.

Подключение к LiveKit **не** требуется — шум connection-agnostic (см. комментарии в сервисе).

## Известные ловушки

| Ловушка | Симптом | Что смотреть в логах |
|---------|---------|----------------------|
| ~~Stale `hasRemoteSpeaker`~~ | ~~Уход в BG сразу после чужой речи — шум не стартует~~ | Устранено: `hasRemoteSpeaker` исключён из `_isEligible` (фикс BG-04 2026-05-27) |
| ~~Dart VM заморожен ОС после остановки шума~~ | ~~Шум не возобновлялся 1+ мин после смолкания спикера~~ | Устранено: шум теперь не останавливается при удалённой речи в BG |
| Dart `Timer` в suspended BG | Долгая тишина в фоне, старт только на событии LiveKit | Нет `isPlaying=true` минутами; исправление: немедленный старт в BG (не полагаться на 1.5 s delay) + watchdog sync |
| Путаница «не слышу» vs «не работает» | Кажется, что фича мертва | `isPlaying=false` при тихой комнате в BG — баг; `isPlaying=true` — сессия жива |
| PTT vs listen-only | После PTT в BG «работает», до PTT — нет | Сравнить `localMicEnabled` и порядок lifecycle |
| Incoming CallKit | Шум не должен мешать звонку | `isSuppressed=true` |
| `deferred_resync` (~400 ms) | Повторная синхронизация после ухода в BG | `source=app_lifecycle_deferred_resync` |
| Stale `isPlaying` после interruption / suspend | В логах `isPlaying=true`, звука нет | Смотреть `playbackActive`; began делает мягкий `ensurePlaybackIfEligible`, ended делает жёсткий restart; watchdog должен вернуть `playbackActive=true` |
| YouTube / другое foreground-audio приложение | Сразу после запуска YouTube приходит `ios_audio_interruption`, затем room падает | PowWow должен оставаться в mixed playback (`mixedWithOthers=true`); на interruption в фоне ищите `source=interruption_began_background`; если был `addTransceiver`, должны появиться `rtc_media_path_failed` и чистый reconnect |
| Будильник / системный alarm | Белый шум кажется пропавшим после alarm в фоне | На `ios_audio_interruption type=began` не должно быть немедленного `Session activation failed`; жёсткий restart должен идти на `type=ended shouldResume=true` |
| Accept CallKit + resume после долгого BG | UI открылось, tribe/LiveKit мёртв | Не должно быть `zombie_disconnect_on_resume` при accept; ищите `zombie_disconnect_skipped` |
| LiveKit disconnect при живом white noise | Room упал в BG, в логах `isPlaying=true` | Шум держит `AVAudioSession`, но **не** гарантирует WebRTC; смотреть BG-09 |
| Resume + SDK reconnect | Лишний disconnect/reconnect после успешного SDK reconnect в фоне | Если был `room_reconnected_event` в BG, на foreground ищите `zombie_disconnect_skipped | reason=background_reconnected`; не должно быть `zombie_disconnect_on_resume` |
| Быстрый lifecycle bounce после reconnect | В логах `isAppInForeground=false`, но `isPlaying=false` / `watchdogActive=false` | Старые lifecycle sync-и должны пропускаться; последняя lifecycle generation должна управлять white noise |
| Quick-tap PTT (< ~300 мс) | Кнопка анимируется, оранжевой точки нет, мик не включается | `mic_stale_enable_reverted` — enable завершился после release; с pre-start fix вероятность снижена, но не исключена (зависит от скорости нативных вызовов); смотреть лог `pre_set_mic_enabled` → пауза → `DID setMicrophoneEnabled` |

## Регрессионная матрица (iOS)

Платформа-приоритет: **iOS**. Android — отдельно при изменении foreground service / audio focus.

| ID | Сценарий | Шаги | Ожидание в логах / поведении | Unit-тест | Последняя проверка |
|----|----------|------|------------------------------|-------------|-------------------|
| **BG-01** | Тихая комната → сразу в фон | Подключиться к room, никто не говорит, **не** нажимать PTT, Home / свайп в BG | В течение ~1–2 с после `app_lifecycle_inactive`: `isPlaying=true`, `hasRemoteSpeaker=false` | `starts when backgrounded and silent` | ✅ 2026-05-27 iPhone 14 — `isPlaying=true` через ~4 с после `paused` |
| **BG-02** | Слушаю → в фон сразу после чужой речи | Уйти в BG сразу после чужой речи | `isPlaying=true` — шум играет независимо от `hasRemoteSpeaker` (фикс BG-04) | `starts immediately in background even with stale remote speaker` | ✅ 2026-05-27 iPhone 14 — powwow_logs2 |
| **BG-03** | В фоне кто-то начал говорить | BG-01 выполнен, удалённый нажимает PTT | `isPlaying=true` (шум 0.0005 vol играет беззвучно), duck (`duckOtherAppsAudio=true`) | `stays playing when remote speaker becomes active` | ✅ 2026-05-27 iPhone 14 — powwow_logs2 |
| **BG-04** | В фоне говоривший замолчал | N/A — шум больше не останавливается в BG при активной речи | `isPlaying=true` непрерывно в течение всего BG-цикла | `keeps playing throughout speaker active/inactive cycle` | ✅ 2026-05-27 фикс + unit-тест; powwow_logs2 iPhone 14 |
| **BG-05** | PTT в foreground → отпустил → в фон | Hold-to-speak нажать/отпустить (держать > 300 мс), затем Home | В BG: `isPlaying=true`, `localMicEnabled=false`; лог `pre_set_mic_enabled` → `DID setMicrophoneEnabled: true` | — | ✅ 2026-05-27 iPhone 14 — powwow_logs2 (шум). ⚠️ quick-tap PTT после reconnect — `mic_stale_enable_reverted` |
| **BG-06** | Возврат в foreground | Из BG-01/02 открыть приложение | `app_lifecycle_resumed`: `isPlaying=false`, `isAppInForeground=true` | `stops when the app comes to foreground` | ✅ 2026-05-27 iPhone 14 — `isPlaying=false, isAppInForeground=true` при `app_lifecycle_resumed` |
| **BG-07** | PTT в фоне не используем | В BG **не** держать PTT (если UI позволяет) | Мик не активен; если mic включён — `isPlaying=false` | `stops when the local microphone is enabled` | — не тестировалось |
| **BG-08** | Incoming call (ringing) | Входящий VoIP / CallKit, приложение в фоне или на экране звонка | `isSuppressed=true`, шум не стартует | `does not start while incoming call flow is suppressed` + `callkit_state_helper_test` | — не тестировалось |
| **BG-09** | Долгая тишина в BG (сессия) | BG-01, оставить 3–5 мин в тихой комнате | Room остаётся connected; `isPlaying=true`, `playbackActive=true`, `watchdogActive=true`; если SDK успел `room_reconnected_event` в BG, foreground resume не должен делать forced reconnect | `skips zombie disconnect after successful background reconnect`, `runs white noise watchdog only in iOS listen-only background` | ⚠️ 2026-05-27 iPhone 14 — powwow_logs2: disconnect в `paused`, затем SDK reconnected; фикс добавлен: `zombie_disconnect_skipped | reason=background_reconnected`. Нужен повторный прогон 3–5 мин |
| **BG-10** | Reconnect после сети | В BG отключить Wi‑Fi на 10–20 с, включить | LiveKit recovery; white noise не должен навсегда оставить `isPlaying=false` при тишине; после быстрого lifecycle bounce применяется только последний lifecycle sync | `applies only the latest lifecycle white-noise sync` | ⚠️ 2026-05-28 iPhone 14 — powwow_logs7: после reconnect + открытия логов старые lifecycle sync-и дали противоречивый `isAppInForeground=false`, но `isPlaying=false`; добавлен generation guard |
| **BG-11** | Remote track mute/unmute в BG | В BG события `TrackMuted` / `TrackUnmuted` | Нет «залипания» `hasRemoteSpeaker`; тишина → `isPlaying=true` | `remote_track_mute_changed` path (ручной) | ✅ 2026-05-27 iPhone 14 — powwow_logs2 |
| **BG-12** | Долгий BG + входящий CallKit → join failure → **Try again** | Принять звонок из фона (>1 мин BG), дождаться баннера ошибки (`Voice room connection failed`), нажать **Try again** | Соединение восстанавливается без kill app; в логах `retry_force_disconnect` → `disconnect_completed` → `connect_livekit_succeeded`; нет `connect_livekit_skipped_busy`; нет `duplicateIdentity` при retry | — | — не тестировалось |
| **BG-13** | PowWow в BG → включить YouTube | BG-01 выполнен, открыть YouTube и запустить видео/звук, затем вернуться в PowWow | LiveKit не должен окончательно отвалиться; YouTube играет вместе с PowWow, remote voice временно duck-ает YouTube, после тишины громкость возвращается; если появляется `Unable to RTCPeerConnection::addTransceiver`, должен быть `rtc_media_path_failed` и чистый reconnect перед дальнейшим PTT | `recovers white noise on interruption only in listen-only background`, `detects LiveKit RTC media path errors` | ⚠️ 2026-05-28 iPhone 14 — powwow_logs5: фоновой SDK reconnect дал `addTransceiver`, после чего media path стал недостоверным; добавлен recovery hook |
| **BG-14** | PowWow в BG → системный будильник | BG-01 выполнен, дождаться alarm, остановить alarm, оставить PowWow в BG | Во время alarm возможен `ios_audio_interruption began`; после `ended shouldResume=true` белый шум восстанавливается, `playbackActive=true`; не должно быть немедленного `Session activation failed` на began | `ensurePlaybackIfEligible does not restart active playback` | ⚠️ 2026-05-28 iPhone 14 — powwow_logs6: на `began` был ранний restart и `Session activation failed`; recovery перенесён на мягкий resync на began + жёсткий restart на ended |

Колонку **Последняя проверка** обновлять после ручного прогона (дата, устройство, имя).

## Android (кратко)

При правках Android foreground service / audio focus:

- Room в фоне с активным foreground service.
- White noise на Android может отличаться — при изменениях завести строки **BG-A01**… в этом файле.

## Автотесты

```bash
flutter test test/background_white_noise_service_test.dart
flutter test test/callkit_state_helper_test.dart
```

Связь сценариев:

| Сценарий | Файл теста |
|----------|------------|
| BG-01, BG-06, suppression | `test/background_white_noise_service_test.dart` |
| BG-02 | `starts when backgrounded with stale remote speaker then silence clears` |
| BG-04 | `restarts immediately when remote speaker stops while in background` |
| BG-08 | `test/callkit_state_helper_test.dart` |

## Процесс при новом баге

1. Воспроизвести на iPhone, сохранить фрагмент логов (lifecycle + `background_white_noise_synced`).
2. Добавить строку в таблицу (новый **BG-XX**) или уточнить существующую.
3. Исправить код + добавить/обновить unit-тест в `background_white_noise_service_test.dart`.
4. Прогнать **всю** матрицу iOS (хотя бы BG-01 … BG-08) — audio-правки ломают соседние кейсы.
5. При смене продуктового поведения обновить [`current-state.md`](current-state.md).

## Связанный код

| Компонент | Путь |
|-----------|------|
| White noise coordinator | `lib/app/services/background_white_noise_service.dart` |
| LiveKit + sync + lifecycle | `lib/screens/tabs/home/live_kit_controller.dart` |
| App lifecycle → LK | `lib/screens/tabs/home/home_controller.dart` |
| CallKit suppression | `lib/app/utils/callkit_state_helper.dart` |
| Глобальные call-флаги | `lib/main.dart` |

## Шаблон отчёта о прогоне (для PR / агента)

```
Устройство: iPhone ___, iOS ___
Сборка: debug / profile
Прогон: BG-01 ✅  BG-02 ✅  BG-03 ✅  …
Заметки: …
Логи (при ❌): вставить 15–30 строк вокруг lifecycle
```
