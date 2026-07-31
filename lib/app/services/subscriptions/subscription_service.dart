import 'dart:async';

import 'package:get/get.dart';

import '../../data/models/user_profile.dart';
import '../firebase/auth_service.dart';
import 'subscription_backend_client.dart';
import 'subscription_diagnostic_log.dart';
import 'subscription_entitlement.dart';
import 'subscription_entitlement_storage.dart';
import 'subscription_product_config.dart';
import 'subscription_purchase.dart';
import 'subscription_state.dart';
import 'subscription_store_gateway.dart';

class SubscriptionService extends GetxService {
  SubscriptionService({
    SubscriptionProductConfig? config,
    SubscriptionStoreGateway? storeGateway,
    SubscriptionBackendClient? backendClient,
    bool autoInitialize = true,
    Duration purchaseReplayDebounce = const Duration(milliseconds: 400),
  }) : _config = config ?? SubscriptionProductConfig.forCurrentStore(),
       _backendClient = backendClient ?? SubscriptionBackendClient(),
       _autoInitialize = autoInitialize,
       _purchaseReplayDebounce = purchaseReplayDebounce {
    _storeGateway =
        storeGateway ?? InAppPurchaseStoreGateway(store: _config.store);
    _state.value = SubscriptionState.initial(
      productsConfigured: _hasProductCatalogSource,
      backendConfigured: _backendClient.isConfigured,
    );
  }

  final SubscriptionProductConfig _config;
  final SubscriptionBackendClient _backendClient;
  final bool _autoInitialize;
  final Duration _purchaseReplayDebounce;

  late final SubscriptionStoreGateway _storeGateway;

  final Rx<SubscriptionState> _state = SubscriptionState.initial().obs;
  StreamSubscription<List<SubscriptionPurchaseDetails>>? _purchaseSubscription;
  StreamSubscription<UserProfile?>? _profileSubscription;
  final List<SubscriptionPurchaseDetails> _terminalPurchaseBuffer =
      <SubscriptionPurchaseDetails>[];
  final Map<String, Future<void>> _inFlightVerifications =
      <String, Future<void>>{};
  Timer? _terminalPurchaseFlushTimer;
  Future<void>? _terminalPurchaseFlush;
  bool _initialized = false;
  bool _entitlementLoadedFromCache = false;
  Future<void>? _initializeFuture;

  SubscriptionState get state => _state.value;

  List<SubscriptionProduct> get products => state.products;

  SubscriptionEntitlement? get entitlement => state.entitlement;

  bool get hasActiveEntitlement => state.hasActiveEntitlement;

  @override
  void onInit() {
    super.onInit();
    if (_autoInitialize) {
      unawaited(initialize());
    }
  }

  Future<void> initialize() {
    return _initializeFuture ??= _initialize();
  }

  Future<void> prepareEntitlementGate({required String source}) async {
    await initialize();

    if (!state.hasActiveEntitlement) {
      await _waitForTerminalPurchasesToSettle();
    }

    subscriptionDiagnosticFlow(
      'entitlement_gate_ready',
      data: _entitlementDiagnosticData(source: source),
    );
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    final SubscriptionEntitlement? cached = _readCachedEntitlement();
    if (cached != null) {
      if (_isUsableCachedEntitlement(cached)) {
        _entitlementLoadedFromCache = true;
        _setState(state.copyWith(entitlement: cached));
        subscriptionDiagnosticFlow(
          'entitlement_cache_loaded',
          data: _entitlementDiagnosticData(source: 'cache'),
        );
      } else {
        await _clearCachedEntitlement();
        subscriptionDiagnosticFlow(
          'entitlement_cache_rejected',
          data: _cachedEntitlementDiagnosticData(cached),
        );
      }
    } else {
      subscriptionDiagnosticFlow(
        'entitlement_cache_empty',
        data: <String, Object?>{'uid': _currentUid() ?? ''},
      );
    }

    _purchaseSubscription = _storeGateway.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error) {
        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.error,
            errorMessage: 'Purchase updates failed',
          ),
        );
      },
    );

    _startAuthListener();

    await loadProducts();
    await refreshEntitlement(silent: true);
  }

  Future<void> loadProducts() async {
    if (!_hasProductCatalogSource) {
      subscriptionDiagnosticFlow(
        'products_not_configured',
        data: <String, Object?>{
          'store': _config.store.apiValue,
          'backendConfigured': _backendClient.isConfigured,
        },
      );
      _setState(
        state.copyWith(
          productsConfigured: false,
          storeAvailable: false,
          products: const <SubscriptionProduct>[],
          phase: SubscriptionServicePhase.idle,
          errorMessage: null,
        ),
      );
      return;
    }

    _setState(
      state.copyWith(
        productsConfigured: true,
        backendConfigured: _backendClient.isConfigured,
        phase: SubscriptionServicePhase.loadingProducts,
        errorMessage: null,
      ),
    );

    try {
      final Set<String> productIds = await _resolveProductIds();

      subscriptionDiagnosticFlow(
        'load_products_start',
        data: <String, Object?>{
          'store': _config.store.apiValue,
          'productIds': productIds.join(', '),
          'backendConfigured': _backendClient.isConfigured,
        },
      );

      final bool available = await _storeGateway.isAvailable();
      if (!available) {
        subscriptionDiagnosticFlow('store_unavailable');
        _setState(
          state.copyWith(
            storeAvailable: false,
            products: const <SubscriptionProduct>[],
            phase: SubscriptionServicePhase.idle,
          ),
        );
        return;
      }

      final SubscriptionProductQuery query = await _storeGateway.queryProducts(
        productIds,
      );
      _logProductQuery(query);
      _setState(
        state.copyWith(
          storeAvailable: true,
          products: query.products,
          notFoundProductIds: query.notFoundIds,
          phase: query.errorMessage == null
              ? SubscriptionServicePhase.idle
              : SubscriptionServicePhase.error,
          errorMessage: query.errorMessage,
        ),
      );
    } catch (error) {
      subscriptionDiagnosticFlow(
        'load_products_failed',
        data: <String, Object?>{'error': _friendlyError(error)},
      );
      _setState(
        state.copyWith(
          storeAvailable: false,
          phase: SubscriptionServicePhase.error,
          errorMessage: _friendlyError(error),
        ),
      );
    }
  }

  void _logProductQuery(SubscriptionProductQuery query) {
    subscriptionDiagnosticFlow(
      'products_loaded',
      data: <String, Object?>{
        'count': query.products.length,
        'notFound': query.notFoundIds.join(', '),
        if (query.errorMessage != null) 'error': query.errorMessage,
      },
    );

    for (final SubscriptionProduct product in query.products) {
      subscriptionDiagnosticFlow(
        'product',
        data: <String, Object?>{
          'id': product.id,
          'title': product.title,
          'price': product.price,
          'currency': product.currencyCode,
        },
      );
    }
  }

  /// Refreshes the known entitlement.
  ///
  /// There is no `GET entitlement/me` endpoint on the backend, so this asks
  /// the store to replay past purchases via `restorePurchases()`; any
  /// resulting purchase flows through [_handlePurchaseUpdates] ->
  /// [_verifyPurchase], which re-validates it against the backend and
  /// updates/caches the entitlement.
  Future<void> refreshEntitlement({bool silent = false}) async {
    if (!state.purchaseValidationReady) {
      if (!silent) {
        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.error,
            errorMessage: _unavailableMessage(),
          ),
        );
      }
      return;
    }

    _setState(
      state.copyWith(
        phase: silent
            ? state.phase
            : SubscriptionServicePhase.loadingEntitlement,
        errorMessage: silent ? state.errorMessage : null,
      ),
    );

    try {
      await _storeGateway.restorePurchases();
      final bool noTransactions = await _restoreCompletedWithoutTransactions();
      if (noTransactions) {
        subscriptionDiagnosticFlow(
          'refresh_entitlement_completed_no_transactions',
        );
        await _clearCacheOnlyEntitlementWithoutCurrentExpiry(
          reason: 'refresh_no_transactions',
        );
      }
      if (!silent &&
          state.phase == SubscriptionServicePhase.loadingEntitlement) {
        _setState(state.copyWith(phase: SubscriptionServicePhase.idle));
      }
    } catch (error) {
      if (!silent) {
        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.error,
            errorMessage: _friendlyError(error),
          ),
        );
      }
    }
  }

  Future<void> buyProduct(SubscriptionProduct product) async {
    if (!state.canPurchase) {
      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.error,
          errorMessage: _unavailableMessage(),
        ),
      );
      return;
    }

    final bool recoveredPendingTransaction =
        await _drainPendingStoreTransactions(
          source: 'before_buy',
          productId: product.id,
        );
    if (recoveredPendingTransaction && _shouldStopBuyAfterPendingDrain) {
      return;
    }

    subscriptionDiagnosticFlow(
      'buy_product_started',
      data: <String, Object?>{
        'productId': product.id,
        'hasPendingVerification': state.pendingVerificationPurchase != null,
      },
    );

    _setState(
      state.copyWith(
        phase: SubscriptionServicePhase.purchasePending,
        errorMessage: null,
      ),
    );

    try {
      final bool started = await _storeGateway.buyProduct(product);
      if (!started) {
        subscriptionDiagnosticFlow(
          'buy_product_not_started',
          data: <String, Object?>{'productId': product.id},
        );
        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.error,
            errorMessage: 'Purchase could not be started',
          ),
        );
      }
    } catch (error) {
      if (_isDuplicateTransactionError(_friendlyError(error))) {
        await _handleDuplicateProductObject(product, error);
        return;
      }

      subscriptionDiagnosticFlow(
        'buy_product_error',
        data: <String, Object?>{
          'productId': product.id,
          'error': _friendlyError(error),
        },
      );
      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.error,
          errorMessage: _friendlyError(error),
        ),
      );
    }
  }

  Future<void> _handleDuplicateProductObject(
    SubscriptionProduct product,
    Object error,
  ) async {
    subscriptionDiagnosticFlow(
      'buy_product_duplicate_transaction',
      data: <String, Object?>{
        'productId': product.id,
        'error': _friendlyError(error),
      },
    );

    final bool recoveredPendingTransaction =
        await _drainPendingStoreTransactions(
          source: 'buy_duplicate',
          productId: product.id,
        );

    if (recoveredPendingTransaction) {
      if (_shouldStopBuyAfterPendingDrain) {
        return;
      }

      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.purchasePending,
          errorMessage: null,
        ),
      );

      try {
        final bool restarted = await _storeGateway.buyProduct(product);
        if (restarted) {
          subscriptionDiagnosticFlow(
            'buy_product_retried_after_pending_drain',
            data: <String, Object?>{'productId': product.id},
          );
          return;
        }
      } catch (retryError) {
        subscriptionDiagnosticFlow(
          'buy_product_retry_after_pending_drain_failed',
          data: <String, Object?>{
            'productId': product.id,
            'error': _friendlyError(retryError),
          },
        );
      }
    }

    _setState(
      state.copyWith(
        phase: SubscriptionServicePhase.error,
        errorMessage: _duplicateTransactionMessage,
      ),
    );
  }

  bool get _shouldStopBuyAfterPendingDrain {
    return state.hasActiveEntitlement ||
        state.pendingVerificationPurchase != null ||
        state.phase == SubscriptionServicePhase.purchasePending ||
        state.phase == SubscriptionServicePhase.verifyingPurchase;
  }

  Future<void> restorePurchases() async {
    if (!state.canRestore) {
      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.error,
          errorMessage: _unavailableMessage(),
        ),
      );
      return;
    }

    subscriptionDiagnosticFlow('restore_purchases_started');

    _setState(
      state.copyWith(
        phase: SubscriptionServicePhase.restoring,
        errorMessage: null,
      ),
    );

    try {
      await _storeGateway.restorePurchases();
      final bool noTransactions = await _restoreCompletedWithoutTransactions();
      if (state.phase == SubscriptionServicePhase.restoring && noTransactions) {
        subscriptionDiagnosticFlow(
          'restore_purchases_completed_no_transactions',
        );
        await _clearCacheOnlyEntitlementWithoutCurrentExpiry(
          reason: 'restore_no_transactions',
        );
        _setState(state.copyWith(phase: SubscriptionServicePhase.idle));
      }
    } catch (error) {
      subscriptionDiagnosticFlow(
        'restore_purchases_failed',
        data: <String, Object?>{'error': _friendlyError(error)},
      );
      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.error,
          errorMessage: _friendlyError(error),
        ),
      );
    }
  }

  Future<void> retryPendingVerification() async {
    final SubscriptionPurchaseDetails? purchase =
        state.pendingVerificationPurchase;
    if (purchase == null) return;

    await _verifyPurchase(purchase);
  }

  void _startAuthListener() {
    if (!Get.isRegistered<AuthService>()) return;

    _profileSubscription = Get.find<AuthService>().stream.listen((
      UserProfile? profile,
    ) {
      if (profile == null) return;
      // If the initial product catalog fetch failed (e.g. Firebase token was
      // not yet available at service startup), retry it now that auth is ready.
      if (!state.storeAvailable) {
        unawaited(loadProducts());
      }
      unawaited(refreshEntitlement(silent: true));
    });
  }

  Future<void> _handlePurchaseUpdates(
    List<SubscriptionPurchaseDetails> purchases,
  ) async {
    final List<SubscriptionPurchaseDetails> terminalPurchases =
        <SubscriptionPurchaseDetails>[];

    for (final SubscriptionPurchaseDetails purchase in purchases) {
      if (purchase.status == SubscriptionPurchaseStatus.pending) {
        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.purchasePending,
            errorMessage: null,
          ),
        );
        continue;
      }

      if (purchase.status == SubscriptionPurchaseStatus.error ||
          purchase.status == SubscriptionPurchaseStatus.canceled) {
        await _completeHandledPurchase(
          purchase,
          event: 'purchase_update_completed_after_error',
        );

        subscriptionDiagnosticFlow(
          'purchase_update_error',
          data: <String, Object?>{
            'productId': purchase.productId,
            'status': purchase.status.name,
            'error': purchase.errorMessage ?? '',
          },
        );

        // StoreKit refuses a new buy attempt when a prior transaction for
        // the same product is still unfinished.  Rather than showing the
        // raw PlatformException, auto-retry the pending verification so the
        // existing transaction is completed and unlocks the product.
        if (purchase.status == SubscriptionPurchaseStatus.error &&
            _isDuplicateTransactionError(purchase.errorMessage)) {
          final SubscriptionPurchaseDetails? pending =
              state.pendingVerificationPurchase;
          subscriptionDiagnosticFlow(
            'purchase_duplicate_transaction_detected',
            data: <String, Object?>{
              'productId': purchase.productId,
              'willAutoRetry': pending != null,
            },
          );
          if (pending != null) {
            await _verifyPurchase(pending);
          } else {
            _setState(
              state.copyWith(
                phase: SubscriptionServicePhase.error,
                errorMessage:
                    'A previous purchase for this product is still pending. '
                    'Tap "Retry validation" to complete it.',
              ),
            );
          }
          continue;
        }

        _setState(
          state.copyWith(
            phase: SubscriptionServicePhase.error,
            errorMessage: _friendlyPurchaseError(
              purchase.errorMessage,
              purchase.status,
            ),
          ),
        );
        continue;
      }

      if (purchase.isTerminalPurchase) {
        terminalPurchases.add(purchase);
      }
    }

    _enqueueTerminalPurchases(terminalPurchases);
  }

  bool get _hasQueuedTerminalPurchases {
    return _terminalPurchaseBuffer.isNotEmpty ||
        _terminalPurchaseFlushTimer != null ||
        _terminalPurchaseFlush != null;
  }

  void _enqueueTerminalPurchases(List<SubscriptionPurchaseDetails> purchases) {
    if (purchases.isEmpty) {
      return;
    }

    _terminalPurchaseBuffer.addAll(purchases);
    _terminalPurchaseFlushTimer?.cancel();
    _terminalPurchaseFlushTimer = Timer(_purchaseReplayDebounce, () {
      _terminalPurchaseFlushTimer = null;
      final Future<void> flush = _flushTerminalPurchaseBuffer();
      _terminalPurchaseFlush = flush;
      unawaited(
        flush.whenComplete(() {
          if (identical(_terminalPurchaseFlush, flush)) {
            _terminalPurchaseFlush = null;
          }
        }),
      );
    });
  }

  Future<void> _flushTerminalPurchaseBuffer() async {
    if (_terminalPurchaseBuffer.isEmpty) {
      return;
    }

    final List<SubscriptionPurchaseDetails> purchases =
        List<SubscriptionPurchaseDetails>.of(_terminalPurchaseBuffer);
    _terminalPurchaseBuffer.clear();
    await _verifyTerminalPurchases(purchases);
  }

  Future<void> _waitForTerminalPurchasesToSettle() async {
    await Future<void>.delayed(_purchaseReplayDebounce);

    while (_terminalPurchaseBuffer.isNotEmpty ||
        _terminalPurchaseFlushTimer != null ||
        _terminalPurchaseFlush != null) {
      final Future<void>? flush = _terminalPurchaseFlush;
      if (flush != null) {
        await flush;
        continue;
      }

      await Future<void>.delayed(_purchaseReplayDebounce);
    }
  }

  Future<void> _verifyTerminalPurchases(
    List<SubscriptionPurchaseDetails> purchases,
  ) async {
    final List<SubscriptionPurchaseDetails> candidates =
        _validationCandidatesFor(purchases);
    if (candidates.length < purchases.length) {
      subscriptionDiagnosticFlow(
        'purchase_replay_batch_collapsed',
        data: <String, Object?>{
          'received': purchases.length,
          'candidates': candidates.length,
        },
      );
    }

    for (final SubscriptionPurchaseDetails purchase in candidates) {
      await _verifyPurchase(purchase);
      if (_purchaseWasVerified(purchase)) {
        await _completeCollapsedTerminalPurchases(
          allPurchases: purchases,
          verifiedPurchase: purchase,
        );
      }
      if (state.hasActiveEntitlement) {
        break;
      }
    }
  }

  bool _purchaseWasVerified(SubscriptionPurchaseDetails purchase) {
    final SubscriptionPurchaseDetails? pending =
        state.pendingVerificationPurchase;
    return pending == null ||
        _verificationDedupeKey(pending) != _verificationDedupeKey(purchase);
  }

  Future<void> _completeCollapsedTerminalPurchases({
    required List<SubscriptionPurchaseDetails> allPurchases,
    required SubscriptionPurchaseDetails verifiedPurchase,
  }) async {
    final String verifiedKey = _verificationDedupeKey(verifiedPurchase);
    final Set<String> completedKeys = <String>{verifiedKey};

    for (final SubscriptionPurchaseDetails purchase in allPurchases) {
      if (!purchase.isTerminalPurchase ||
          purchase.productId != verifiedPurchase.productId) {
        continue;
      }

      final String purchaseKey = _verificationDedupeKey(purchase);
      if (!completedKeys.add(purchaseKey)) {
        continue;
      }

      await _completeHandledPurchase(
        purchase,
        event: 'collapsed_purchase_completed_after_validation',
      );
    }
  }

  List<SubscriptionPurchaseDetails> _validationCandidatesFor(
    List<SubscriptionPurchaseDetails> purchases,
  ) {
    if (purchases.length <= 1) return purchases;

    final Map<String, SubscriptionPurchaseDetails> latestByProduct =
        <String, SubscriptionPurchaseDetails>{};
    final Set<String> seenTransactions = <String>{};

    for (final SubscriptionPurchaseDetails purchase in purchases) {
      final String transactionKey = _verificationDedupeKey(purchase);
      if (!seenTransactions.add(transactionKey)) {
        continue;
      }

      final SubscriptionPurchaseDetails? current =
          latestByProduct[purchase.productId];
      if (current == null ||
          _purchaseSortValue(purchase) > _purchaseSortValue(current)) {
        latestByProduct[purchase.productId] = purchase;
      }
    }

    final List<SubscriptionPurchaseDetails> candidates = latestByProduct.values
        .toList(growable: false);
    candidates.sort(
      (SubscriptionPurchaseDetails a, SubscriptionPurchaseDetails b) =>
          _purchaseSortValue(b).compareTo(_purchaseSortValue(a)),
    );
    return candidates;
  }

  int _purchaseSortValue(SubscriptionPurchaseDetails purchase) {
    final String? purchaseId = purchase.purchaseId;
    final int? purchaseIdValue = purchaseId == null
        ? null
        : int.tryParse(purchaseId);
    if (purchaseIdValue != null) return purchaseIdValue;

    final String? transactionDate = purchase.transactionDate;
    if (transactionDate == null || transactionDate.isEmpty) return 0;

    final int? rawTimestamp = int.tryParse(transactionDate);
    if (rawTimestamp != null) return rawTimestamp;

    final String normalized = transactionDate.contains('T')
        ? transactionDate
        : transactionDate.replaceFirst(' ', 'T');
    return DateTime.tryParse(normalized)?.millisecondsSinceEpoch ?? 0;
  }

  /// Joins concurrent verify calls for the same store transaction so StoreKit
  /// replays (purchased + restored on startup) only hit the backend once.
  Future<void> _verifyPurchase(SubscriptionPurchaseDetails purchase) async {
    final String key = _verificationDedupeKey(purchase);
    final Future<void>? inFlight = _inFlightVerifications[key];
    if (inFlight != null) {
      subscriptionDiagnosticFlow(
        'verify_purchase_deduped',
        data: <String, Object?>{
          'productId': purchase.productId,
          'purchaseId': purchase.purchaseId ?? '',
          'status': purchase.status.name,
        },
      );
      return inFlight;
    }

    final Future<void> verification = _runVerifyPurchase(purchase);
    _inFlightVerifications[key] = verification;
    try {
      await verification;
    } finally {
      if (identical(_inFlightVerifications[key], verification)) {
        _inFlightVerifications.remove(key);
      }
    }
  }

  Future<void> _runVerifyPurchase(SubscriptionPurchaseDetails purchase) async {
    _logPurchaseReceipt(purchase);

    _setState(
      state.copyWith(
        phase: SubscriptionServicePhase.verifyingPurchase,
        pendingVerificationPurchase: purchase,
        errorMessage: null,
      ),
    );

    try {
      final SubscriptionEntitlement entitlement = await _backendClient
          .verifyPurchase(purchase);
      await _completeHandledPurchase(
        purchase,
        event: 'purchase_completed_after_validation',
      );
      await _cacheEntitlement(entitlement);
      _entitlementLoadedFromCache = false;
      subscriptionDiagnosticFlow(
        'verify_purchase_succeeded',
        data: <String, Object?>{
          'productId': purchase.productId,
          'active': entitlement.active,
          'environment': entitlement.environment ?? '',
        },
      );
      _setState(
        state.copyWith(
          entitlement: entitlement,
          phase: SubscriptionServicePhase.idle,
          errorMessage: null,
          pendingVerificationPurchase: null,
        ),
      );
    } catch (error) {
      subscriptionDiagnosticFlow(
        'verify_purchase_failed',
        data: _purchaseVerificationErrorData(error, purchase),
      );
      _setState(
        state.copyWith(
          phase: SubscriptionServicePhase.error,
          errorMessage: _friendlyError(error),
          pendingVerificationPurchase: purchase,
        ),
      );
    }
  }

  Future<bool> _drainPendingStoreTransactions({
    required String source,
    String? productId,
  }) async {
    List<SubscriptionPurchaseDetails> purchases;
    try {
      purchases = await _storeGateway.pendingPurchases();
    } catch (error) {
      subscriptionDiagnosticFlow(
        'pending_store_transactions_load_failed',
        data: <String, Object?>{
          'source': source,
          'productId': productId ?? '',
          'error': _friendlyError(error),
        },
      );
      return false;
    }

    if (purchases.isEmpty) {
      return false;
    }

    subscriptionDiagnosticFlow(
      'pending_store_transactions_loaded',
      data: <String, Object?>{
        'source': source,
        'productId': productId ?? '',
        'count': purchases.length,
      },
    );

    final List<SubscriptionPurchaseDetails> terminalPurchases =
        <SubscriptionPurchaseDetails>[];

    for (final SubscriptionPurchaseDetails purchase in purchases) {
      if (purchase.status == SubscriptionPurchaseStatus.pending) {
        if (productId == null || purchase.productId == productId) {
          _setState(
            state.copyWith(
              phase: SubscriptionServicePhase.purchasePending,
              errorMessage: null,
            ),
          );
        }
        continue;
      }

      if (purchase.status == SubscriptionPurchaseStatus.error ||
          purchase.status == SubscriptionPurchaseStatus.canceled) {
        await _completeHandledPurchase(
          purchase,
          event: 'pending_store_transaction_completed_after_error',
        );
        continue;
      }

      if (purchase.isTerminalPurchase) {
        terminalPurchases.add(purchase);
      }
    }

    if (terminalPurchases.isNotEmpty) {
      await _verifyTerminalPurchases(terminalPurchases);
    }

    return true;
  }

  Future<void> _completeHandledPurchase(
    SubscriptionPurchaseDetails purchase, {
    required String event,
  }) async {
    if (!purchase.pendingCompletePurchase) return;

    try {
      await _storeGateway.completePurchase(purchase);
      subscriptionDiagnosticFlow(
        event,
        data: <String, Object?>{
          'productId': purchase.productId,
          'purchaseId': purchase.purchaseId ?? '',
          'status': purchase.status.name,
        },
      );
    } catch (error) {
      subscriptionDiagnosticFlow(
        'complete_purchase_failed',
        data: <String, Object?>{
          'productId': purchase.productId,
          'purchaseId': purchase.purchaseId ?? '',
          'status': purchase.status.name,
          'error': _friendlyError(error),
        },
      );
      rethrow;
    }
  }

  String _verificationDedupeKey(SubscriptionPurchaseDetails purchase) {
    final String? purchaseId = purchase.purchaseId;
    if (purchaseId != null && purchaseId.isNotEmpty) {
      return '${purchase.store.apiValue}:$purchaseId';
    }
    return '${purchase.store.apiValue}:${purchase.productId}:'
        '${purchase.verificationData.serverVerificationData.hashCode}';
  }

  void _logPurchaseReceipt(SubscriptionPurchaseDetails purchase) {
    final SubscriptionVerificationData verification = purchase.verificationData;

    subscriptionDiagnosticFlow(
      'purchase_receipt_captured',
      data: <String, Object?>{
        'store': purchase.store.apiValue,
        'productId': purchase.productId,
        'purchaseId': purchase.purchaseId,
        'transactionDate': purchase.transactionDate,
        'status': purchase.status.name,
        'verificationSource': verification.source,
        'serverVerificationDataLength':
            verification.serverVerificationData.length,
        'localVerificationDataLength':
            verification.localVerificationData.length,
      },
    );

    subscriptionDiagnosticFlow(
      'purchase_server_verification_data',
      data: <String, Object?>{'payload': verification.serverVerificationData},
    );

    subscriptionDiagnosticFlow(
      'purchase_local_verification_data',
      data: <String, Object?>{'payload': verification.localVerificationData},
    );
  }

  SubscriptionEntitlement? _readCachedEntitlement() {
    try {
      return SubscriptionEntitlementStorage.read(uid: _currentUid());
    } catch (error) {
      subscriptionDiagnosticFlow(
        'entitlement_cache_read_failed',
        data: <String, Object?>{'error': error.toString()},
      );
      return null;
    }
  }

  bool _isUsableCachedEntitlement(SubscriptionEntitlement entitlement) {
    return entitlement.hasAccess;
  }

  Future<void> _cacheEntitlement(SubscriptionEntitlement entitlement) async {
    try {
      await SubscriptionEntitlementStorage.write(
        entitlement,
        uid: _currentUid(),
      );
    } catch (error) {
      subscriptionDiagnosticFlow(
        'entitlement_cache_write_failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _clearCachedEntitlement() async {
    try {
      await SubscriptionEntitlementStorage.clear(uid: _currentUid());
    } catch (error) {
      subscriptionDiagnosticFlow(
        'entitlement_cache_clear_failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<bool> _restoreCompletedWithoutTransactions() async {
    if (_hasQueuedTerminalPurchases) return false;

    if (_purchaseReplayDebounce > Duration.zero) {
      await Future<void>.delayed(_purchaseReplayDebounce);
    }
    return !_hasQueuedTerminalPurchases;
  }

  Future<void> _clearCacheOnlyEntitlementWithoutCurrentExpiry({
    required String reason,
  }) async {
    final SubscriptionEntitlement? entitlement = state.entitlement;
    if (!_entitlementLoadedFromCache ||
        entitlement == null ||
        entitlement.expiresAt != null ||
        entitlement.isLifetimeProduct) {
      return;
    }

    await _clearCachedEntitlement();
    _entitlementLoadedFromCache = false;
    subscriptionDiagnosticFlow(
      'entitlement_cache_cleared',
      data: <String, Object?>{
        ..._cachedEntitlementDiagnosticData(entitlement),
        'reason': reason,
      },
    );
    _setState(state.copyWith(entitlement: null));
  }

  Map<String, Object?> _cachedEntitlementDiagnosticData(
    SubscriptionEntitlement entitlement,
  ) {
    return <String, Object?>{
      'active': entitlement.active,
      'hasAccess': entitlement.hasAccess,
      'store': entitlement.store.apiValue,
      'productId': entitlement.productId ?? '',
      'entitlementSource': entitlement.source.apiValue,
      'expiresAt': entitlement.expiresAt?.toIso8601String() ?? '',
      'validatedAt': entitlement.validatedAt?.toIso8601String() ?? '',
      'environment': entitlement.environment ?? '',
    };
  }

  Map<String, Object?> _entitlementDiagnosticData({required String source}) {
    final SubscriptionEntitlement? entitlement = state.entitlement;
    return <String, Object?>{
      'source': source,
      'active': entitlement?.active ?? false,
      'hasAccess': state.hasActiveEntitlement,
      'phase': state.phase.name,
      'productId': entitlement?.productId ?? '',
      'entitlementSource': entitlement?.source.apiValue ?? '',
      'expiresAt': entitlement?.expiresAt?.toIso8601String() ?? '',
      'validatedAt': entitlement?.validatedAt?.toIso8601String() ?? '',
    };
  }

  String? _currentUid() {
    if (Get.isRegistered<AuthService>()) {
      return Get.find<AuthService>().uid;
    }
    return null;
  }

  void _setState(SubscriptionState nextState) {
    _state.value = nextState;
  }

  bool get _hasProductCatalogSource {
    return _config.store != SubscriptionStoreKind.unknown &&
        _backendClient.isConfigured;
  }

  /// Resolves the product IDs to query from the store.
  ///
  /// Product IDs come from the backend catalog API. Local config/env product
  /// IDs are intentionally not used as a runtime fallback, so the paywall does
  /// not silently show stale store products when the catalog is unavailable.
  Future<Set<String>> _resolveProductIds() async {
    try {
      final Set<String> apiIds = await _backendClient.fetchProductIds(
        _config.store,
      );
      if (apiIds.isNotEmpty) {
        subscriptionDiagnosticFlow(
          'products_ids_from_api',
          data: <String, Object?>{
            'ids': apiIds.join(', '),
            'count': apiIds.length,
          },
        );
        return apiIds;
      }
      subscriptionDiagnosticFlow('products_ids_api_empty');
      throw SubscriptionBackendException(
        'Subscription product catalog is empty for ${_config.store.apiValue}',
      );
    } catch (error) {
      subscriptionDiagnosticFlow(
        'products_ids_api_failed',
        data: <String, Object?>{'error': _friendlyError(error)},
      );
      rethrow;
    }
  }

  String _unavailableMessage() {
    if (!_hasProductCatalogSource) {
      return 'Subscription product catalog is not configured';
    }
    if (!_backendClient.isConfigured) {
      return 'Subscription server validation is not configured';
    }
    if (!state.storeAvailable) {
      return 'The store is not available';
    }
    return 'Subscriptions are not available';
  }

  Map<String, Object?> _purchaseVerificationErrorData(
    Object error,
    SubscriptionPurchaseDetails purchase,
  ) {
    final Map<String, Object?> data = <String, Object?>{
      'productId': purchase.productId,
      'purchaseId': purchase.purchaseId,
      'error': _friendlyError(error),
    };

    if (error is SubscriptionBackendException) {
      data['statusCode'] = error.statusCode;
      if (error.details != null) {
        data['responseBody'] = error.details.toString();
      }
    }

    return data;
  }

  String _friendlyError(Object error) {
    if (error is SubscriptionBackendException) {
      final String message = error.message;
      final int? statusCode = error.statusCode;
      if (statusCode != null && !message.contains('$statusCode')) {
        return '$message (HTTP $statusCode)';
      }
      return message;
    }
    return error.toString();
  }

  /// Returns a user-readable message for a purchase stream error/canceled
  /// update, stripping raw PlatformException wrappers where possible.
  String _friendlyPurchaseError(
    String? rawError,
    SubscriptionPurchaseStatus status,
  ) {
    if (status == SubscriptionPurchaseStatus.canceled) {
      return 'Purchase was cancelled';
    }
    if (rawError == null) return 'Purchase was not completed';
    if (_isDuplicateTransactionError(rawError)) {
      return _duplicateTransactionMessage;
    }
    // Strip "PlatformException(code, message, ...)" to just the message part.
    final RegExpMatch? match = RegExp(
      r'^PlatformException\([^,]+,\s*(.+?)(?:,\s*[^,]*,\s*[^)]*)??\)$',
      dotAll: true,
    ).firstMatch(rawError.trim());
    if (match != null) {
      final String inner = match.group(1)?.trim() ?? '';
      if (inner.isNotEmpty) return inner;
    }
    return rawError;
  }

  static bool _isDuplicateTransactionError(String? errorMessage) {
    return errorMessage?.contains('storekit_duplicate_product_object') ?? false;
  }

  static const String _duplicateTransactionMessage =
      'A previous purchase for this product is still pending. '
      'Please wait a moment and try again.';

  @override
  void onClose() {
    _terminalPurchaseFlushTimer?.cancel();
    _purchaseSubscription?.cancel();
    _profileSubscription?.cancel();
    super.onClose();
  }
}
