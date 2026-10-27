import 'repository.dart';

class ArtifactFailure implements Exception {
  final String message;
  const ArtifactFailure(this.message);
  @override
  String toString() => message;
}

abstract class ArtifactPreview extends Repository {
  /// One source-bound operation at a time, including the native viewer lifetime.
  Future<void> open(String url, {required void Function(double) progress});
  Future<void> cancel();
}
