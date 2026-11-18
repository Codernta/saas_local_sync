/// Production-ready, offline-first multi-tenant synchronization engine for Flutter & Dart.
///
/// Features strict logical tenant isolation, optimistic UI queue with
/// exponential backoff and jitter, persistent disk queues, and pluggable
/// conflict resolution.
library;

export 'src/tenant_scope.dart';
export 'src/sync_queue.dart';
export 'src/conflict_resolver.dart';
export 'src/sync_repository.dart';
export 'src/connectivity.dart';
export 'src/transport.dart';
export 'src/sync_client.dart';
export 'src/flutter_helpers.dart';
