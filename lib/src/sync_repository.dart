import 'dart:async';
import 'tenant_scope.dart';
import 'sync_queue.dart';
import 'conflict_resolver.dart';

/// The synchronization state of a local entity relative to the remote server.
enum SyncState {
  /// Entity is acknowledged and synchronized with the remote backend.
  synced,

  /// Entity was created offline; creation is queued locally.
  pendingCreation,

  /// Entity was modified offline; update mutation is queued locally.
  pendingUpdate,

  /// Entity was marked deleted locally; deletion mutation is queued.
  pendingDeletion,

  /// Entity encountered a version divergence and was reconciled via conflict resolution.
  conflictResolved;

  String toJson() => name;
  static SyncState fromJson(String value) {
    return SyncState.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SyncState.synced,
    );
  }
}

/// Base contract for entities managed by [SyncRepository].
abstract class SyncEntity {
  /// The unique identifier of this entity.
  String get id;

  /// The tenant/workspace identifier this entity strictly belongs to.
  String get tenantId;

  /// The timestamp of the most recent modification.
  DateTime get updatedAt;

  /// Whether the entity is soft-deleted.
  bool get isDeleted;

  /// Current synchronization status.
  SyncState get syncState;

  /// Serializes the entity to a JSON map.
  Map<String, dynamic> toJson();
}

/// Generic, type-safe repository managing optimistic UI mutations, local caching,
/// and background sync queuing for entity type [T].
class SyncRepository<T extends SyncEntity, ID> {
  final String entityType;
  final String endpoint;
  final ScopedStoreWrapper<T> store;
  final SyncQueueManager queueManager;
  final ConflictResolver<T> conflictResolver;
  final T Function(Map<String, dynamic> json) fromJson;
  final Map<String, dynamic> Function(T entity) toJson;
  final T Function(T entity, SyncState syncState, DateTime updatedAt)?
      withSyncState;

  SyncRepository({
    required this.entityType,
    required this.endpoint,
    required this.store,
    required this.queueManager,
    ConflictResolver<T>? conflictResolver,
    required this.fromJson,
    required this.toJson,
    this.withSyncState,
  }) : conflictResolver =
            conflictResolver ?? ConflictResolver<T>.lastWriteWins();

  /// The active tenant scope.
  TenantScope get scope => store.scope;

  /// Optimistically saves [entity] to local storage and enqueues a background sync operation.
  ///
  /// Immediately available in the UI with `syncState = pendingUpdate` or `pendingCreation`.
  Future<void> save(T entity) async {
    scope.ensureActiveTenant(entity.tenantId);

    final existing = await store.get(entity.id.toString());
    final isNew = existing == null;

    final targetState =
        isNew ? SyncState.pendingCreation : SyncState.pendingUpdate;
    final updatedEntity = withSyncState != null
        ? withSyncState!(entity, targetState, DateTime.now().toUtc())
        : entity;

    // 1. Optimistic Local Persistence
    await store.put(entity.id.toString(), updatedEntity);

    // 2. Queue Mutation
    final operation = SyncOperation(
      tenantId: entity.tenantId,
      endpoint: endpoint,
      entityType: entityType,
      entityId: entity.id.toString(),
      operationType:
          isNew ? SyncOperationType.create : SyncOperationType.update,
      payload: toJson(updatedEntity),
      timestamp: DateTime.now().toUtc(),
    );

    await queueManager.enqueue(operation);
  }

  /// Optimistically deletes the entity with [id].
  ///
  /// Marks the entity as deleted locally and enqueues a delete mutation.
  Future<void> delete(ID id) async {
    final key = id.toString();
    final existing = await store.get(key);
    if (existing == null) return;

    scope.ensureActiveTenant(existing.tenantId);

    // If never synced before (created and deleted while offline), we can just remove locally
    if (existing.syncState == SyncState.pendingCreation) {
      await store.delete(key);
      return;
    }

    // Otherwise mark deleted locally and queue deletion
    if (withSyncState != null) {
      final softDeleted = withSyncState!(
          existing, SyncState.pendingDeletion, DateTime.now().toUtc());
      await store.put(key, softDeleted);
    } else {
      await store.delete(key);
    }

    final operation = SyncOperation(
      tenantId: existing.tenantId,
      endpoint: '$endpoint/$key',
      entityType: entityType,
      entityId: key,
      operationType: SyncOperationType.delete,
      timestamp: DateTime.now().toUtc(),
    );

    await queueManager.enqueue(operation);
  }

  /// Finds an entity by [id] in the active tenant cache.
  Future<T?> findById(ID id, {bool includeDeleted = false}) async {
    final item = await store.get(id.toString());
    if (item == null) return null;
    if (!includeDeleted && item.isDeleted) return null;
    return item;
  }

  /// Finds all entities for the active tenant.
  Future<List<T>> findAll({bool includeDeleted = false}) async {
    final all = await store.getAll();
    final items = all.values.where((item) {
      if (!includeDeleted && item.isDeleted) return false;
      return true;
    }).toList();
    return items;
  }

  /// Reactive stream of all entities for the active tenant.
  Stream<List<T>> watchAll({bool includeDeleted = false}) {
    return store.watchAll().map((map) {
      return map.values.where((item) {
        if (!includeDeleted && item.isDeleted) return false;
        return true;
      }).toList();
    });
  }

  /// Reactive stream of a single entity.
  Stream<T?> watchById(ID id, {bool includeDeleted = false}) {
    final key = id.toString();
    return store.watchAll().map((map) {
      final item = map[key];
      if (item == null) return null;
      if (!includeDeleted && item.isDeleted) return null;
      return item;
    });
  }

  /// Acknowledges successful remote synchronization of an entity.
  Future<void> onRemoteAcknowledged(
    String entityId, {
    Map<String, dynamic>? serverData,
    DateTime? serverTimestamp,
  }) async {
    final existing = await store.get(entityId);
    if (existing == null) return;

    if (existing.syncState == SyncState.pendingDeletion) {
      // Remove completely from disk once remote delete confirms
      await store.delete(entityId);
      return;
    }

    T syncedEntity;
    if (serverData != null) {
      final updatedJson = Map<String, dynamic>.from(serverData);
      updatedJson['syncState'] = SyncState.synced.toJson();
      syncedEntity = fromJson(updatedJson);
      if (withSyncState != null) {
        syncedEntity = withSyncState!(
          syncedEntity,
          SyncState.synced,
          serverTimestamp ?? syncedEntity.updatedAt,
        );
      }
    } else if (withSyncState != null) {
      syncedEntity = withSyncState!(
        existing,
        SyncState.synced,
        serverTimestamp ?? existing.updatedAt,
      );
    } else {
      syncedEntity = existing;
    }

    await store.put(entityId, syncedEntity);
  }

  /// Handles a conflict reported by the server when pushing local mutations.
  Future<ConflictResolution<T>> onRemoteConflict({
    required String entityId,
    required Map<String, dynamic> remoteData,
    required DateTime serverTimestamp,
  }) async {
    final local = await store.get(entityId);
    final remote = fromJson(remoteData);

    if (local == null) {
      await store.put(entityId, remote);
      return ConflictResolution<T>(
        resolvedEntity: remote,
        strategyUsed: ConflictStrategy.serverAuthoritative,
        needsRemotePush: false,
        details: 'No local entity found; accepted remote state.',
      );
    }

    final context = ConflictContext<T>(
      entityId: entityId,
      tenantId: local.tenantId,
      localEntity: local,
      remoteEntity: remote,
      localTimestamp: local.updatedAt,
      remoteTimestamp: serverTimestamp,
    );

    final resolution = conflictResolver.resolve(context);

    // Apply resolved state locally
    final resolvedWithStatus = withSyncState != null
        ? withSyncState!(
            resolution.resolvedEntity,
            resolution.needsRemotePush
                ? SyncState.pendingUpdate
                : SyncState.conflictResolved,
            DateTime.now().toUtc(),
          )
        : resolution.resolvedEntity;

    await store.put(entityId, resolvedWithStatus);

    // If resolution needs remote push, re-queue
    if (resolution.needsRemotePush) {
      final retryOp = SyncOperation(
        tenantId: local.tenantId,
        endpoint: endpoint,
        entityType: entityType,
        entityId: entityId,
        operationType: SyncOperationType.update,
        payload: toJson(resolvedWithStatus),
        timestamp: DateTime.now().toUtc(),
      );
      await queueManager.enqueue(retryOp);
    }

    return resolution;
  }

  /// Directly applies an incoming remote entity (from a pull or WebSocket push).
  Future<void> applyRemoteUpdate(
    T remoteEntity, {
    DateTime? remoteTimestamp,
  }) async {
    scope.ensureActiveTenant(remoteEntity.tenantId);

    final local = await store.get(remoteEntity.id);
    final effectiveRemoteTimestamp =
        remoteTimestamp ?? remoteEntity.updatedAt;

    if (local == null) {
      if (!remoteEntity.isDeleted) {
        await store.put(remoteEntity.id, remoteEntity);
      }
      return;
    }

    // If local has pending mutations, resolve conflict
    if (local.syncState == SyncState.pendingUpdate ||
        local.syncState == SyncState.pendingCreation) {
      await onRemoteConflict(
        entityId: remoteEntity.id,
        remoteData: toJson(remoteEntity),
        serverTimestamp: effectiveRemoteTimestamp,
      );
      return;
    }

    // Otherwise remote directly updates local
    if (remoteEntity.isDeleted) {
      await store.delete(remoteEntity.id);
    } else {
      await store.put(remoteEntity.id, remoteEntity);
    }
  }
}
