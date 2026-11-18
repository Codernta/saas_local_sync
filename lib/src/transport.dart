import 'dart:async';
import 'package:meta/meta.dart';
import 'sync_queue.dart';

/// Status classification for transport responses.
enum TransportResultStatus {
  success,
  conflict,
  failure;
}

/// The result returned by a [RemoteTransport] when pushing an operation.
@immutable
class TransportResult {
  final TransportResultStatus status;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? remoteData;
  final DateTime? serverTimestamp;
  final String? errorMessage;
  final bool isPermanent;
  final int? statusCode;

  const TransportResult._({
    required this.status,
    this.data,
    this.remoteData,
    this.serverTimestamp,
    this.errorMessage,
    this.isPermanent = false,
    this.statusCode,
  });

  /// Successfully acknowledged by the remote server.
  factory TransportResult.success({
    Map<String, dynamic>? data,
    DateTime? serverTimestamp,
  }) {
    return TransportResult._(
      status: TransportResultStatus.success,
      data: data,
      serverTimestamp: serverTimestamp ?? DateTime.now().toUtc(),
      statusCode: 200,
    );
  }

  /// Server rejected the operation due to a state conflict (e.g. HTTP 409 Conflict).
  ///
  /// Contains [remoteData] and [serverTimestamp] representing the current server state.
  factory TransportResult.conflict({
    required Map<String, dynamic> remoteData,
    DateTime? serverTimestamp,
    String? message,
  }) {
    return TransportResult._(
      status: TransportResultStatus.conflict,
      remoteData: remoteData,
      serverTimestamp: serverTimestamp ?? DateTime.now().toUtc(),
      errorMessage: message ?? 'Version conflict detected on server.',
      statusCode: 409,
    );
  }

  /// Network, server (5xx), or client validation (4xx) failure.
  factory TransportResult.failure({
    required String error,
    bool isPermanent = false,
    int? statusCode,
  }) {
    return TransportResult._(
      status: TransportResultStatus.failure,
      errorMessage: error,
      isPermanent: isPermanent,
      statusCode: statusCode,
    );
  }

  bool get isSuccess => status == TransportResultStatus.success;
  bool get isConflict => status == TransportResultStatus.conflict;
  bool get isFailure => status == TransportResultStatus.failure;

  @override
  String toString() =>
      'TransportResult(status: ${status.name}, statusCode: $statusCode, error: $errorMessage)';
}

/// Pluggable interface for communicating with remote backend services (REST, GraphQL, gRPC, WebSocket).
abstract class RemoteTransport {
  /// Pushes a single queued mutation to the backend.
  Future<TransportResult> push(SyncOperation operation);

  /// Pulls remote updates for a given [tenantId] since [since].
  Future<List<Map<String, dynamic>>> pull(
    String tenantId, {
    String? entityType,
    DateTime? since,
  });
}

/// A comprehensive, multi-tenant in-memory mock backend.
///
/// Simulates realistic server behaviors: latency, network drops, versioning,
/// server-side state edits, and conflict generation (409 Conflict).
class MockRemoteTransport implements RemoteTransport {
  Duration simulatedLatency;
  bool simulateNetworkDown;
  int? forceFailWithCode;
  final Set<String> _conflictTriggerEntityIds = {};

  // tenantId -> (entityId -> payload)
  final Map<String, Map<String, Map<String, dynamic>>> _remoteDatabase = {};

  MockRemoteTransport({
    this.simulatedLatency = const Duration(milliseconds: 50),
    this.simulateNetworkDown = false,
  });

  /// Injects or updates an entity directly on the server to simulate edits
  /// by other team members or external web users.
  void injectServerChange(
    String tenantId,
    String entityId,
    Map<String, dynamic> data,
  ) {
    _remoteDatabase.putIfAbsent(tenantId, () => {})[entityId] =
        Map<String, dynamic>.from(data);
  }

  /// Arms a conflict trigger for a specific [entityId].
  ///
  /// The next time a mutation is pushed for this entity, the server will
  /// respond with [TransportResult.conflict] containing the simulated remote state.
  void triggerConflictOnNextPush(String entityId) {
    _conflictTriggerEntityIds.add(entityId);
  }

  /// Retrieves the current mock server record for an entity.
  Map<String, dynamic>? getServerRecord(String tenantId, String entityId) {
    return _remoteDatabase[tenantId]?[entityId];
  }

  /// Clears remote database.
  void clear() {
    _remoteDatabase.clear();
    _conflictTriggerEntityIds.clear();
  }

  @override
  Future<TransportResult> push(SyncOperation operation) async {
    if (simulatedLatency > Duration.zero) {
      await Future.delayed(simulatedLatency);
    }

    if (simulateNetworkDown) {
      return TransportResult.failure(
        error: 'Network connection failed: Unable to reach host.',
        isPermanent: false,
      );
    }

    if (forceFailWithCode != null) {
      final code = forceFailWithCode!;
      final isPerm = code >= 400 && code < 500 && code != 408 && code != 429;
      return TransportResult.failure(
        error: 'HTTP $code Server Error',
        isPermanent: isPerm,
        statusCode: code,
      );
    }

    final tenantId = operation.tenantId;
    final entityId = operation.entityId;

    // Check if a simulated conflict is armed
    if (_conflictTriggerEntityIds.contains(entityId)) {
      _conflictTriggerEntityIds.remove(entityId);

      // Current server payload (or generate synthetic divergent payload)
      final existing = _remoteDatabase[tenantId]?[entityId] ??
          {
            'id': entityId,
            'tenantId': tenantId,
            'title': 'Conflicting edit made on web portal',
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'version': 99,
          };

      return TransportResult.conflict(
        remoteData: existing,
        serverTimestamp: DateTime.now().toUtc(),
        message: 'Resource was modified on the server while offline.',
      );
    }

    final tenantStore = _remoteDatabase.putIfAbsent(tenantId, () => {});

    switch (operation.operationType) {
      case SyncOperationType.create:
      case SyncOperationType.update:
      case SyncOperationType.custom:
        if (operation.payload != null) {
          final serverData = Map<String, dynamic>.from(operation.payload!);
          serverData['serverSyncedAt'] =
              DateTime.now().toUtc().toIso8601String();
          tenantStore[entityId] = serverData;
          return TransportResult.success(
            data: serverData,
            serverTimestamp: DateTime.now().toUtc(),
          );
        }
        return TransportResult.success(serverTimestamp: DateTime.now().toUtc());

      case SyncOperationType.delete:
        tenantStore.remove(entityId);
        return TransportResult.success(serverTimestamp: DateTime.now().toUtc());
    }
  }

  @override
  Future<List<Map<String, dynamic>>> pull(
    String tenantId, {
    String? entityType,
    DateTime? since,
  }) async {
    if (simulatedLatency > Duration.zero) {
      await Future.delayed(simulatedLatency);
    }

    if (simulateNetworkDown) {
      throw Exception(
          'Network connection failed: Unable to pull remote updates.');
    }

    final tenantStore = _remoteDatabase[tenantId] ?? {};
    final list = <Map<String, dynamic>>[];

    for (final record in tenantStore.values) {
      if (since != null && record.containsKey('updatedAt')) {
        try {
          final updatedAt = DateTime.parse(record['updatedAt'] as String);
          if (updatedAt.isBefore(since)) continue;
        } catch (_) {}
      }
      list.add(Map<String, dynamic>.from(record));
    }

    return list;
  }
}
