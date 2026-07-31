import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../../app/routes/app_routes.dart';
import '../../app/services/subscriptions/subscription_entitlement.dart';
import '../../app/services/subscriptions/subscription_product_config.dart';
import '../../app/services/subscriptions/subscription_product_ids.dart';
import '../../app/services/subscriptions/subscription_service.dart';
import '../../app/services/subscriptions/subscription_state.dart';
import '../../app/services/subscriptions/subscription_store_gateway.dart';
import '../../app/theme.dart';
import '../../main.dart';
import '../../test_screen/test_log_helper.dart';
import '../../test_screen/test_logs_screen.dart';

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  String? _selectedProductKey;

  @override
  void initState() {
    super.initState();
    final SubscriptionService service = Get.find<SubscriptionService>();
    if (!service.state.storeAvailable) {
      service.loadProducts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final SubscriptionService service = Get.find<SubscriptionService>();
    final bool blockingPaywall = _isBlockingPaywall;

    return Obx(() {
      final SubscriptionState state = service.state;
      _navigateToDashboardWhenUnlocked(
        blockingPaywall: blockingPaywall,
        state: state,
      );
      final List<SubscriptionProduct> products = _sortedProductsByPrice(
        state.products,
      );
      final SubscriptionProduct? selectedProduct = _selectedProduct(
        state,
        products,
      );

      return Stack(
        children: [
          Scaffold(
            backgroundColor: AppColors.greyBg,
            appBar: AppBar(
              automaticallyImplyLeading: !blockingPaywall,
              backgroundColor: AppColors.greyBg,
              elevation: 0,
              title: Text(
                'Subscription'.toUpperCase(),
                style: AppTextStyle.mainRegular.copyWith(fontSize: 20),
              ),
              actions: [
                IconButton(
                  tooltip: 'Test logs',
                  icon: const Icon(Icons.article_outlined),
                  onPressed: () {
                    testPrintLS(
                      DiagnosticLog.ui(
                        'SubscriptionScreen',
                        'logs_open_tapped',
                      ),
                    );
                    Get.to(() => const TestLogsScreen());
                  },
                ),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: () async {
                if (!state.storeAvailable) {
                  await service.loadProducts();
                }
                await service.refreshEntitlement();
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                children: [
                  _buildHero(state, products),
                  if (state.errorMessage != null) ...[
                    const SizedBox(height: 14),
                    _buildErrorBanner(state.errorMessage!),
                  ],
                  const SizedBox(height: 18),
                  _buildBenefits(),
                  const SizedBox(height: 18),
                  _buildPlansSection(
                    state: state,
                    products: products,
                    selectedProduct: selectedProduct,
                  ),
                  const SizedBox(height: 18),
                  _buildPrimaryCta(service, state, selectedProduct),
                  const SizedBox(height: 12),
                  _buildRestoreAction(service, state),
                ],
              ),
            ),
          ),
          if (_showBusyOverlay(state))
            _buildBusyOverlay(
              context,
              state: state,
              showBackButton: !blockingPaywall,
            ),
        ],
      );
    });
  }

  bool get _isBlockingPaywall {
    final Object? arguments = Get.arguments;
    return arguments is Map && arguments['blockingPaywall'] == true;
  }

  void _navigateToDashboardWhenUnlocked({
    required bool blockingPaywall,
    required SubscriptionState state,
  }) {
    if (!blockingPaywall || !state.hasActiveEntitlement) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Get.currentRoute == AppRoutes.subscription) {
        Get.offAllNamed(AppRoutes.dashboard);
      }
    });
  }

  Widget _buildHero(
    SubscriptionState state,
    List<SubscriptionProduct> products,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Stay close to your tribe',
          style: AppTextStyle.mainBold.copyWith(fontSize: 30, height: 1.06),
        ),
        const SizedBox(height: 10),
        Text(
          'Choose a PowWow plan to keep family audio rooms, invites, and shared moments unlocked.',
          style: AppTextStyle.mainRegular.copyWith(
            color: AppColors.blackText3,
            height: 1.35,
          ),
        ),
        if (state.hasActiveEntitlement) ...[
          const SizedBox(height: 14),
          _buildActiveBadge(state.entitlement, products),
        ],
      ],
    );
  }

  Widget _buildActiveBadge(
    SubscriptionEntitlement? entitlement,
    List<SubscriptionProduct> products,
  ) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: AppColors.greenText.withValues(alpha: 0.12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: AppColors.greenText,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _activeSubscriptionText(entitlement, products),
              style: AppTextStyle.mainSemibold.copyWith(
                color: AppColors.greenText,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.redBg2,
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: AppColors.orangeBg,
            size: 22,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyle.mainRegular.copyWith(
                color: AppColors.blackText2,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _showBusyOverlay(SubscriptionState state) {
    return state.phase == SubscriptionServicePhase.purchasePending ||
        state.phase == SubscriptionServicePhase.verifyingPurchase ||
        state.phase == SubscriptionServicePhase.restoring;
  }

  Widget _buildBusyOverlay(
    BuildContext context, {
    required SubscriptionState state,
    required bool showBackButton,
  }) {
    return Positioned.fill(
      child: Stack(
        children: [
          ModalBarrier(
            key: const ValueKey<String>('subscription_validation_overlay'),
            dismissible: false,
            color: AppColors.blackText.withValues(alpha: 0.2),
          ),
          Center(
            child: Material(
              color: AppColors.whiteBg,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: AppColors.greenText,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      _busyOverlayTitle(state),
                      style: AppTextStyle.mainSemibold.copyWith(
                        fontSize: 15,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showBackButton)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 4,
              left: 4,
              child: IconButton(
                key: const ValueKey<String>('subscription_validation_back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const BackButtonIcon(),
                onPressed: () {
                  Navigator.of(context).maybePop();
                },
              ),
            ),
        ],
      ),
    );
  }

  String _busyOverlayTitle(SubscriptionState state) {
    if (state.phase == SubscriptionServicePhase.restoring) {
      return 'Restoring...';
    }
    return 'Validating...';
  }

  Widget _buildBenefits() {
    const List<String> benefits = <String>[
      'Unlimited family voice room access',
      'Invite and manage your tribe',
      'Reliable realtime audio connection',
    ];

    return _buildCard(
      child: Column(
        children: [
          for (final String benefit in benefits) ...[
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.greenText.withValues(alpha: 0.1),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    color: AppColors.greenText,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    benefit,
                    style: AppTextStyle.mainRegular.copyWith(
                      color: AppColors.blackText2,
                    ),
                  ),
                ),
              ],
            ),
            if (benefit != benefits.last) const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _buildPlansSection({
    required SubscriptionState state,
    required List<SubscriptionProduct> products,
    required SubscriptionProduct? selectedProduct,
  }) {
    if (!state.productsConfigured) {
      return _buildUnavailableCard(
        title: 'Product catalog is not configured',
        message: 'Configure POWWOW_IAP_API_BASE_URL for store builds.',
      );
    }

    if (state.phase == SubscriptionServicePhase.loadingProducts) {
      return _buildLoadingCard(
        title: 'Loading plans',
        message: 'Loading plans from the store...',
      );
    }

    if (!state.storeAvailable) {
      return _buildUnavailableCard(
        title: 'Store unavailable',
        message: 'Purchases are unavailable on this device right now.',
      );
    }

    if (products.isEmpty) {
      return _buildUnavailableCard(
        title: 'No products found',
        message: state.notFoundProductIds.isEmpty
            ? 'The store did not return subscription products.'
            : 'Missing products: ${state.notFoundProductIds.join(', ')}',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Choose your plan'.toUpperCase(),
          style: AppTextStyle.mainRegular.copyWith(
            fontSize: 13,
            color: AppColors.greyText,
          ),
        ),
        const SizedBox(height: 10),
        for (final SubscriptionProduct product in products) ...[
          _buildPlanTile(
            product: product,
            selected: _productKey(product) == _productKey(selectedProduct),
            current: _isCurrentPlan(state, product),
            onTap: state.canPurchase && !_isCurrentPlan(state, product)
                ? () {
                    setState(() {
                      _selectedProductKey = _productKey(product);
                    });
                  }
                : null,
          ),
          if (product != products.last) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildPlanTile({
    required SubscriptionProduct product,
    required bool selected,
    required bool current,
    required VoidCallback? onTap,
  }) {
    final Color borderColor = current
        ? AppColors.greyBg4
        : selected
        ? AppColors.greenText
        : AppColors.greyBg3;
    final Color backgroundColor = current
        ? AppColors.greyBg2
        : AppColors.whiteBg;
    final Color titleColor = current ? AppColors.greyText : AppColors.blackText;
    final Color priceColor = current
        ? AppColors.greyText2
        : AppColors.greenText;

    return Opacity(
      opacity: current ? 0.65 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: backgroundColor,
            border: Border.all(color: borderColor, width: selected ? 2 : 1),
            boxShadow: [
              if (selected && !current)
                BoxShadow(
                  color: AppColors.greenText.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                current
                    ? Icons.check_circle_rounded
                    : selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: current ? AppColors.greyText2 : AppColors.greenText,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _planTitle(product),
                  style: AppTextStyle.mainBold.copyWith(
                    fontSize: 17,
                    color: titleColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                product.price,
                textAlign: TextAlign.right,
                style: AppTextStyle.mainBold.copyWith(
                  color: priceColor,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryCta(
    SubscriptionService service,
    SubscriptionState state,
    SubscriptionProduct? selectedProduct,
  ) {
    final bool hasBusyOverlay = _showBusyOverlay(state);
    final bool current =
        selectedProduct != null && _isCurrentPlan(state, selectedProduct);
    final bool enabled =
        selectedProduct != null && state.canPurchase && !current;

    return FilledButton(
      onPressed: enabled
          ? () {
              testPrintLS(
                DiagnosticLog.ui(
                  'SubscriptionScreen',
                  'subscribe_tapped',
                  data: {'productId': selectedProduct.id},
                ),
              );
              service.buyProduct(selectedProduct);
            }
          : null,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.greenText,
        foregroundColor: AppColors.whiteText,
        disabledBackgroundColor: hasBusyOverlay
            ? AppColors.greenText
            : AppColors.greyBg4,
        disabledForegroundColor: AppColors.whiteText,
        minimumSize: const Size.fromHeight(54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      child: Text(_ctaTitle(state, selectedProduct, current)),
    );
  }

  Widget _buildRestoreAction(
    SubscriptionService service,
    SubscriptionState state,
  ) {
    return TextButton(
      onPressed: state.canRestore
          ? () {
              testPrintLS(
                DiagnosticLog.ui('SubscriptionScreen', 'restore_tapped'),
              );
              service.restorePurchases();
            }
          : null,
      style: TextButton.styleFrom(
        disabledForegroundColor: _showBusyOverlay(state)
            ? AppColors.greenText
            : null,
      ),
      child: const Text('Restore purchases'),
    );
  }

  Widget _buildUnavailableCard({
    required String title,
    required String message,
  }) {
    return _buildCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.greyText, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyle.mainBold.copyWith(fontSize: 17),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  style: AppTextStyle.mainRegular.copyWith(
                    color: AppColors.greyText,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingCard({required String title, required String message}) {
    return _buildCard(
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.greenText,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyle.mainBold.copyWith(fontSize: 17),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: AppTextStyle.mainRegular.copyWith(
                    color: AppColors.greyText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppColors.whiteBg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: child,
    );
  }

  SubscriptionProduct? _selectedProduct(
    SubscriptionState state,
    List<SubscriptionProduct> products,
  ) {
    if (products.isEmpty) return null;

    final String? selectedKey = _selectedProductKey;
    if (selectedKey != null) {
      for (final SubscriptionProduct product in products) {
        if (_productKey(product) == selectedKey) {
          return product;
        }
      }
    }

    for (final SubscriptionProduct product in products) {
      if (!_isCurrentPlan(state, product)) {
        return product;
      }
    }

    return products.first;
  }

  List<SubscriptionProduct> _sortedProductsByPrice(
    List<SubscriptionProduct> products,
  ) {
    final List<({int index, SubscriptionProduct product})> indexedProducts =
        <({int index, SubscriptionProduct product})>[];
    for (int index = 0; index < products.length; index += 1) {
      indexedProducts.add((index: index, product: products[index]));
    }

    indexedProducts.sort((
      ({int index, SubscriptionProduct product}) left,
      ({int index, SubscriptionProduct product}) right,
    ) {
      final int priceOrder = right.product.rawPrice.compareTo(
        left.product.rawPrice,
      );
      if (priceOrder != 0) return priceOrder;
      return left.index.compareTo(right.index);
    });

    return indexedProducts
        .map((entry) => entry.product)
        .toList(growable: false);
  }

  bool _isCurrentPlan(SubscriptionState state, SubscriptionProduct product) {
    final SubscriptionEntitlement? entitlement = state.entitlement;
    if (entitlement == null || !entitlement.hasAccess) return false;
    if (entitlement.productId != product.id) return false;

    if (entitlement.store == SubscriptionStoreKind.playStore &&
        product.id == SubscriptionProductIds.playSubscription) {
      return false;
    }

    return true;
  }

  String _productKey(SubscriptionProduct? product) {
    if (product == null) return '';
    return '${product.id}:${product.planLabel ?? ''}:${product.price}';
  }

  String _planTitle(SubscriptionProduct product) {
    final String? label = product.planLabel;
    if (label != null && label.trim().isNotEmpty) return label;
    return product.title;
  }

  String _ctaTitle(
    SubscriptionState state,
    SubscriptionProduct? selectedProduct,
    bool current,
  ) {
    if (state.phase == SubscriptionServicePhase.loadingProducts) {
      return 'Loading plans';
    }
    if (current) return 'Current plan';
    if (!state.productsConfigured) return 'Catalog unavailable';
    if (!state.storeAvailable) return 'Store unavailable';
    if (!state.backendConfigured) return 'Purchases unavailable';
    if (selectedProduct == null) return 'Choose a plan';
    if (state.canPurchase || _showBusyOverlay(state)) {
      return 'Continue with ${_planTitle(selectedProduct)}';
    }
    return 'Please wait';
  }

  String _activeSubscriptionText(
    SubscriptionEntitlement? entitlement,
    List<SubscriptionProduct> products,
  ) {
    if (entitlement == null) return 'Active subscription';
    final String? productId = entitlement.productId;
    if (productId == null || productId.isEmpty) return 'Active subscription';

    final SubscriptionProduct? product = _productForEntitlement(
      entitlement,
      products,
    );
    final String planName = product == null
        ? _fallbackPlanName(productId)
        : _planTitle(product);
    return 'Active subscription: $planName';
  }

  SubscriptionProduct? _productForEntitlement(
    SubscriptionEntitlement entitlement,
    List<SubscriptionProduct> products,
  ) {
    final String? productId = entitlement.productId;
    if (productId == null || productId.isEmpty) return null;

    for (final SubscriptionProduct product in products) {
      if (product.id == productId) return product;
    }

    return null;
  }

  String _fallbackPlanName(String productId) {
    return switch (productId) {
      SubscriptionProductIds.appStoreYear => 'Full access yearly',
      SubscriptionProductIds.appStoreMonth => 'Full access monthly',
      SubscriptionProductIds.appStoreWeek => 'Full access weekly',
      SubscriptionProductIds.appStoreLife => 'Full access lifetime',
      _ => productId,
    };
  }
}

//td//td Legacy paywall kept intentionally unused while the new classic paywall is routed.
class LegacySubscriptionScreen extends StatelessWidget {
  const LegacySubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SubscriptionService service = Get.find<SubscriptionService>();
    final bool blockingPaywall = _isBlockingPaywall;

    return Scaffold(
      backgroundColor: AppColors.greyBg,
      appBar: AppBar(
        automaticallyImplyLeading: !blockingPaywall,
        backgroundColor: AppColors.greyBg,
        elevation: 0,
        title: Text(
          'Subscription'.toUpperCase(),
          style: AppTextStyle.mainRegular.copyWith(fontSize: 20),
        ),
        actions: [
          IconButton(
            tooltip: 'Test logs',
            icon: const Icon(Icons.article_outlined),
            onPressed: () {
              testPrintLS(
                DiagnosticLog.ui('SubscriptionScreen', 'logs_open_tapped'),
              );
              Get.to(() => const TestLogsScreen());
            },
          ),
        ],
      ),
      body: Obx(() {
        final SubscriptionState state = service.state;
        _navigateToDashboardWhenUnlocked(
          blockingPaywall: blockingPaywall,
          state: state,
        );
        return RefreshIndicator(
          onRefresh: () async {
            if (!state.storeAvailable) {
              await service.loadProducts();
            }
            await service.refreshEntitlement();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            children: [
              _buildStatusCard(service, state),
              const SizedBox(height: 16),
              _buildProductsCard(service, state),
              const SizedBox(height: 16),
              _buildRestoreCard(service, state),
            ],
          ),
        );
      }),
    );
  }

  bool get _isBlockingPaywall {
    final Object? arguments = Get.arguments;
    return arguments is Map && arguments['blockingPaywall'] == true;
  }

  void _navigateToDashboardWhenUnlocked({
    required bool blockingPaywall,
    required SubscriptionState state,
  }) {
    if (!blockingPaywall || !state.hasActiveEntitlement) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Get.currentRoute == AppRoutes.subscription) {
        Get.offAllNamed(AppRoutes.dashboard);
      }
    });
  }

  Widget _buildStatusCard(
    SubscriptionService service,
    SubscriptionState state,
  ) {
    final SubscriptionEntitlement? entitlement = state.entitlement;
    final bool isActive = state.hasActiveEntitlement;

    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('Status'),
          const SizedBox(height: 16),
          Text(
            _statusTitle(state),
            style: AppTextStyle.mainBold.copyWith(fontSize: 20),
          ),
          const SizedBox(height: 8),
          Text(
            _statusSubtitle(state),
            style: AppTextStyle.mainRegular.copyWith(color: AppColors.greyText),
          ),
          if (entitlement != null) ...[
            const SizedBox(height: 16),
            _buildEntitlementDetails(entitlement),
          ],
          if (state.needsVerificationRetry) ...[
            const SizedBox(height: 16),
            _buildPrimaryButton(
              title: 'Retry validation',
              isBusy: state.phase == SubscriptionServicePhase.verifyingPurchase,
              onPressed: service.retryPendingVerification,
            ),
          ] else if (!isActive) ...[
            const SizedBox(height: 16),
            Text(
              'Subscribe to unlock PowWow.',
              style: AppTextStyle.mainRegular.copyWith(
                fontSize: 13,
                color: AppColors.greyText2,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProductsCard(
    SubscriptionService service,
    SubscriptionState state,
  ) {
    if (!state.productsConfigured) {
      return _buildCard(
        child: _buildUnavailableMessage(
          title: 'Product catalog is not configured',
          message: 'Configure POWWOW_IAP_API_BASE_URL for store builds.',
        ),
      );
    }

    if (state.phase == SubscriptionServicePhase.loadingProducts) {
      return _buildCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionTitle('Plans'),
            const SizedBox(height: 12),
            Text(
              'Loading plans from the store...',
              style: AppTextStyle.mainRegular.copyWith(
                color: AppColors.greyText,
              ),
            ),
          ],
        ),
      );
    }

    if (!state.storeAvailable) {
      return _buildCard(
        child: _buildUnavailableMessage(
          title: 'Store unavailable',
          message: 'Purchases are unavailable on this device right now.',
        ),
      );
    }

    if (state.products.isEmpty) {
      return _buildCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildUnavailableMessage(
              title: 'No products found',
              message: state.notFoundProductIds.isEmpty
                  ? 'The store did not return subscription products.'
                  : 'Missing products: ${state.notFoundProductIds.join(', ')}',
            ),
            if (state.notFoundProductIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Check Play Console / App Store Connect product status.',
                style: AppTextStyle.mainRegular.copyWith(
                  fontSize: 13,
                  color: AppColors.greyText2,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle('Plans'),
          if (!state.backendConfigured) ...[
            const SizedBox(height: 12),
            Text(
              'Purchases are disabled until POWWOW_IAP_API_BASE_URL is configured.',
              style: AppTextStyle.mainRegular.copyWith(
                fontSize: 13,
                color: AppColors.greyText2,
              ),
            ),
          ],
          const SizedBox(height: 12),
          for (final SubscriptionProduct product in state.products) ...[
            _buildProductRow(service, state, product),
            if (product != state.products.last) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _buildRestoreCard(
    SubscriptionService service,
    SubscriptionState state,
  ) {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionTitle('Restore'),
          const SizedBox(height: 12),
          Text(
            'Restore checks store purchases and asks the backend to validate entitlement.',
            style: AppTextStyle.mainRegular.copyWith(color: AppColors.greyText),
          ),
          const SizedBox(height: 16),
          _buildSecondaryButton(
            title: 'Restore purchases',
            isBusy: state.phase == SubscriptionServicePhase.restoring,
            onPressed: state.canRestore
                ? () {
                    testPrintLS(
                      DiagnosticLog.ui('SubscriptionScreen', 'restore_tapped'),
                    );
                    service.restorePurchases();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildProductRow(
    SubscriptionService service,
    SubscriptionState state,
    SubscriptionProduct product,
  ) {
    final bool isBuying =
        state.phase == SubscriptionServicePhase.purchasePending;
    final bool isVerifying =
        state.phase == SubscriptionServicePhase.verifyingPurchase;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.greyBg2,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            product.planLabel ?? product.title,
            style: AppTextStyle.mainBold.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 4),
          Text(
            product.planLabel == null ? product.id : product.title,
            style: AppTextStyle.mainRegular.copyWith(
              fontSize: 12,
              color: AppColors.greyText2,
            ),
          ),
          if (product.description.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              product.description,
              style: AppTextStyle.mainRegular.copyWith(
                color: AppColors.greyText,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  product.price,
                  style: AppTextStyle.mainSemibold.copyWith(
                    color: AppColors.greenText,
                  ),
                ),
              ),
              _buildCompactButton(
                title: isVerifying
                    ? 'Validating'
                    : state.canPurchase
                    ? 'Subscribe'
                    : 'Preview',
                isBusy: isBuying || isVerifying,
                onPressed: state.canPurchase
                    ? () {
                        testPrintLS(
                          DiagnosticLog.ui(
                            'SubscriptionScreen',
                            'subscribe_tapped',
                            data: {'productId': product.id},
                          ),
                        );
                        service.buyProduct(product);
                      }
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEntitlementDetails(SubscriptionEntitlement entitlement) {
    final DateTime? expiresAt = entitlement.expiresAt;
    final String source = entitlement.isFamilyShared
        ? 'Family shared'
        : 'Purchased';
    final List<String> details = <String>[
      source,
      if (entitlement.productId != null) entitlement.productId!,
      if (expiresAt != null) 'Expires ${DateFormat.yMMMd().format(expiresAt)}',
    ];

    return Text(
      details.join(' · '),
      style: AppTextStyle.mainRegular.copyWith(
        fontSize: 13,
        color: AppColors.greyText,
      ),
    );
  }

  Widget _buildUnavailableMessage({
    required String title,
    required String message,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionTitle(title),
        const SizedBox(height: 12),
        Text(
          message,
          style: AppTextStyle.mainRegular.copyWith(color: AppColors.greyText),
        ),
      ],
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: AppColors.whiteBg,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: child,
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title.toUpperCase(),
      style: AppTextStyle.mainRegular.copyWith(
        fontSize: 13,
        color: AppColors.greyText,
      ),
    );
  }

  Widget _buildPrimaryButton({
    required String title,
    required bool isBusy,
    required VoidCallback? onPressed,
  }) {
    return FilledButton(
      onPressed: isBusy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.greenText,
        foregroundColor: AppColors.whiteText,
      ),
      child: Text(isBusy ? 'Please wait...' : title),
    );
  }

  Widget _buildSecondaryButton({
    required String title,
    required bool isBusy,
    required VoidCallback? onPressed,
  }) {
    return OutlinedButton(
      onPressed: isBusy ? null : onPressed,
      child: Text(isBusy ? 'Please wait...' : title),
    );
  }

  Widget _buildCompactButton({
    required String title,
    required bool isBusy,
    required VoidCallback? onPressed,
  }) {
    return FilledButton(
      onPressed: isBusy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.greenText,
        foregroundColor: AppColors.whiteText,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(isBusy ? 'Wait' : title),
    );
  }

  String _statusTitle(SubscriptionState state) {
    if (state.hasActiveEntitlement) return 'Active';
    if (state.needsVerificationRetry) return 'Waiting for validation';
    if (state.phase == SubscriptionServicePhase.loadingProducts) {
      return 'Loading plans';
    }
    if (state.phase == SubscriptionServicePhase.loadingEntitlement) {
      return 'Checking status';
    }
    if (state.phase == SubscriptionServicePhase.purchasePending) {
      return 'Purchase pending';
    }
    if (state.phase == SubscriptionServicePhase.verifyingPurchase) {
      return 'Validating purchase';
    }
    if (state.phase == SubscriptionServicePhase.restoring) {
      return 'Restoring purchases';
    }
    if (state.isUnavailable) return 'Unavailable';
    if (state.phase == SubscriptionServicePhase.error) return 'Needs attention';
    return 'Not active';
  }

  String _statusSubtitle(SubscriptionState state) {
    if (state.errorMessage != null) return state.errorMessage!;
    if (state.hasActiveEntitlement) {
      return 'Backend validation confirmed subscription access.';
    }
    if (state.needsVerificationRetry) {
      return 'The purchase was received, but server validation did not finish.';
    }
    if (!state.productsConfigured) {
      return 'Product IDs are not configured for this platform.';
    }
    if (!state.backendConfigured) {
      return 'Store catalog loaded. Backend validation is not configured yet.';
    }
    if (!state.storeAvailable) {
      return 'The store is not available on this device.';
    }
    return 'Choose a plan when subscriptions are ready.';
  }
}
