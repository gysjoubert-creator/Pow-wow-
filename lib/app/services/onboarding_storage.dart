import 'package:get_storage/get_storage.dart';

abstract interface class OnboardingCompletionStore {
  bool get isCompleted;

  Future<void> markCompleted();
}

class OnboardingStorage implements OnboardingCompletionStore {
  OnboardingStorage({GetStorage? box}) : _box = box ?? GetStorage();

  static const String completionKey = 'powwow_onboarding_completed_v1';

  final GetStorage _box;

  @override
  bool get isCompleted => _box.read<bool>(completionKey) ?? false;

  @override
  Future<void> markCompleted() => _box.write(completionKey, true);
}
