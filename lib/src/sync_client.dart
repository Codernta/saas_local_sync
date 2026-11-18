import 'dart:async';
import 'package:meta/meta.dart';
import 'tenant_scope.dart';
import 'sync_queue.dart';
import 'connectivity.dart';
import 'transport.dart';
import 'sync_repository.dart';

/// The high-level status of the synchronization engine.
enum SyncStatus {
  /// All pending mutations are synchronized; engine is idle.
  synced,

  /// Actively processing queued operations or pulling remote changes.
  syncing,

  /// Device is offline; mutations are queued locally on disk.
  offline,

  /// An error occurred during the last synchronization attempt.
  error;

  String toJson() => name;
}

/// Immutable snapshot representing the live state of [SyncEngine].
@immutable
class SyncEngineState {
  final String? activeTenantId;
  final SyncStatus status;
  final int pendingOperationsCount;
  final DateTime? lastSyncTime;
  final String? lastError;
  final bool isOnline;

  const SyncEngineState({
    this.activeTenantId,
    required this.status,
    this.pendingOperationsCount = 0,
    this.lastSyncTime,
    this.lastError,
    this.isOnline = true,
  });

  SyncEngineState copyWith({
    String? activeTenantId,
    SyncStatus? status,
    int? pendingOperationsCount,
    DateTime? lastSyncTime,
    String? lastError,
    bool? isOnline,
    bool clearLastError = false,
  }) {
    return SyncEngineState(
      activeTenantId: activeTenantId ?? this.activeTenantId,
      status: status ?? this.status,
      pendingOperationsCount:
          pendingOperationsCount ?? this.pendingOperationsCount,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      isOnline: isOnline ?? this.isOnline,
    );
  }

  @override
  String toString() =>
      'SyncEngineState(tenant: $activeTenantId, status: ${status.name}, pending: $pendingOperationsCount, online: $isOnline, lastSync: $lastSyncTime)';
}

/// Configuration options for [SyncEngine].
class SyncEngineOptions {
  /// Periodic interval for background sync ticks when online. Set to `null` to disable.
  final Duration? periodicSyncInterval;

  /// Whether to automatically flush the queue immediately upon coming back online.
  final bool autoSyncOnOnline;

  /// Maximum number of queued operations to process in a single flush batch.
  final int batchSize;

  const SyncEngineOptions({
    this.periodicSyncInterval = const Duration(seconds: 30),
    this.autoSyncOnOnline = true,
    this.batchSize = 50,
  });
}

/// The central orchestrator for offline-first, multi-tenant synchronization.
///
/// Coordinates:
/// - Tenant isolation and switching ([TenantScope])
/// - Persistent local mutation queue with exponential backoff ([SyncQueueManager])
/// - Online/offline network detection ([ConnectivityMonitor])
/// - Remote transport communication ([RemoteTransport])
/// - Reactive event streams ([SyncStatus] & [SyncEngineState])
class SyncEngine {
  final TenantScope tenantScope;
  final SyncQueueManager queueManager;
  final ConnectivityMonitor connectivity;
  final RemoteTransport transport;
  final SyncEngineOptions options;

  final Map<String, SyncRepository> _repositories = {};
  final StreamController<SyncEngineState> _stateController =
      StreamController<SyncEngineState>.broadcast();
  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();

  SyncEngineState _currentState;
  Timer? _periodicTimer;
  StreamSubscription<bool>? _connectivitySub;
  StreamSubscription<String?>? _tenantSub;
  StreamSubscription<SyncOperation>? _queueSub;

  bool _isDisposed = false;
  bool _isSyncing = false;
  bool _isPaused = false;

  SyncEngine({
    required this.tenantScope,
    required this.queueManager,
    required this.connectivity,
    required this.transport,
    this.options = const SyncEngineOptions(),
  }) : _currentState = SyncEngineState(
          activeTenantId: tenantScope.activeTenantIdOrNull,
          status: SyncStatus.synced,
        );

  /// Current state snapshot.
  SyncEngineState get currentState => _currentState;

  /// Current sync status.
  SyncStatus get currentStatus => _currentState.status;

  /// Reactive stream of full state snapshots.
  Stream<SyncEngineState> get stateStream => _stateController.stream;

  /// Reactive stream of [SyncStatus] changes.
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// Registers a typed entity repository to receive sync lifecycle acknowledgements
  /// and conflict resolution events.
  void registerRepository(SyncRepository repository) {
    _repositories[repository.entityType] = repository;
  }

  /// Initializes the engine, establishing network listeners and background sync timers.
  Future<void> initialize() async {
    await queueManager.init();

    final online = await connectivity.isOnline;
    int pending = 0;
    if (tenantScope.hasActiveTenant) {
      pending = await queueManager.getPendingCount(tenantScope.activeTenantId);
    }

    _updateState(_currentState.copyWith(
      isOnline: online,
      pendingOperationsCount: pending,
      status: online ? SyncStatus.synced : SyncStatus.offline,
    ));

    // Connectivity listener
    _connectivitySub =
        connectivity.onConnectivityChanged.listen((isOnline) async {
      _updateState(_currentState.copyWith(
        isOnline: isOnline,
        status: isOnline ? SyncStatus.synced : SyncStatus.offline,
      ));

      if (isOnline && options.autoSyncOnOnline && !_isPaused) {
        await sync();
      }
    });

    // Tenant change listener
    _tenantSub = tenantScope.onTenantChanged.listen((newTenant) async {
      int count = 0;
      if (newTenant != null) {
        count = await queueManager.getPendingCount(newTenant);
      }
      _updateState(_currentState.copyWith(
        activeTenantId: newTenant,
        pendingOperationsCount: count,
        clearLastError: true,
      ));

      if (newTenant != null && _currentState.isOnline && !_isPaused) {
        await sync();
      }
    });

    // Queue mutation listener
    _queueSub = queueManager.onQueueChanged.listen((_) async {
      if (tenantScope.hasActiveTenant) {
        final count =
            await queueManager.getPendingCount(tenantScope.activeTenantId);
        _updateState(_currentState.copyWith(pendingOperationsCount: count));
      }
    });

    // Background periodic sync timer
    if (options.periodicSyncInterval != null &&
        options.periodicSyncInterval! > Duration.zero) {
      _periodicTimer = Timer.periodic(options.periodicSyncInterval!, (_) async {
        if (_currentState.isOnline && !_isPaused && !_isSyncing) {
          await sync();
        }
      });
    }

    // Initial flush if already online
    if (online && options.autoSyncOnOnline && tenantScope.hasActiveTenant) {
      await sync();
    }
  }

  /// Switches the active tenant workspace.
  ///
  /// Updates [TenantScope] and immediately flushes any queued operations
  /// for the newly activated tenant.
  Future<void> switchTenant(String newTenantId) async {
    tenantScope.setTenant(newTenantId);
  }

  /// Manually triggers a synchronization cycle for the active tenant.
  ///
  /// Flushes pending queued mutations, acknowledges results, resolves conflicts,
  /// and updates [SyncStatus].
  Future<void> sync() async {
    if (_isSyncing || _isDisposed || _isPaused) return;

    if (!_currentState.isOnline) {
      _updateState(_currentState.copyWith(status: SyncStatus.offline));
      return;
    }

    if (!tenantScope.hasActiveTenant) {
      _updateState(_currentState.copyWith(status: SyncStatus.synced));
      return;
    }

    final tenantId = tenantScope.activeTenantId;
    _isSyncing = true;
    _updateState(_currentState.copyWith(status: SyncStatus.syncing));

    try {
      // 1. Flush pending queue operations
      final readyOps = await queueManager.getReadyOperations(tenantId);
      final batch = readyOps.take(options.batchSize).toList();

      for (final op in batch) {
        if (_isDisposed || _isPaused) break;
        // Verify tenant hasn't switched mid-batch
        if (tenantScope.activeTenantIdOrNull != tenantId) break;

        await queueManager.markInFlight(op);
        final result = await transport.push(op);

        final repo = _repositories[op.entityType];

        if (result.isSuccess) {
          await repo?.onRemoteAcknowledged(
            op.entityId,
            serverData: result.data,
            serverTimestamp: result.serverTimestamp,
          );
          await queueManager.markCompleted(op.id);
        } else if (result.isConflict) {
          if (repo != null && result.remoteData != null) {
            await repo.onRemoteConflict(
              entityId: op.entityId,
              remoteData: result.remoteData!,
              serverTimestamp: result.serverTimestamp ?? DateTime.now().toUtc(),
            );
            // Completed current conflict op (retry op is re-enqueued by repo if needed)
            await queueManager.markCompleted(op.id);
          } else {
            // No handler for conflict, mark failed
            await queueManager.markFailed(
              op,
              error: result.errorMessage ?? 'Unhandled conflict',
            );
          }
        } else {
          // Failure (network error or server 5xx)
          await queueManager.markFailed(
            op,
            error: result.errorMessage ?? 'Push operation failed',
            isPermanent: result.isPermanent,
          );
        }
      }

      // 2. Refresh pending count
      final remainingPending = await queueManager.getPendingCount(tenantId);

      _updateState(_currentState.copyWith(
        status: SyncStatus.synced,
        pendingOperationsCount: remainingPending,
        lastSyncTime: DateTime.now().toUtc(),
        clearLastError: true,
      ));
    } catch (e) {
      _updateState(_currentState.copyWith(
        status: SyncStatus.error,
        lastError: e.toString(),
      ));
    } finally {
      _isSyncing = false;
    }
  }

  /// Pauses background sync operations.
  void pause() {
    _isPaused = true;
  }

  /// Resumes background sync operations.
  void resume() {
    _isPaused = false;
    if (_currentState.isOnline && tenantScope.hasActiveTenant) {
      sync();
    }
  }

  void _updateState(SyncEngineState newState) {
    if (_isDisposed) return;
    final statusChanged = _currentState.status != newState.status;
    _currentState = newState;

    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
    if (statusChanged && !_statusController.isClosed) {
      _statusController.add(newState.status);
    }
  }

  /// Disposes resources, timers, and stream controllers.
  Future<void> dispose() async {
    _isDisposed = true;
    _periodicTimer?.cancel();
    await _connectivitySub?.cancel();
    await _tenantSub?.cancel();
    await _queueSub?.cancel();
    await _stateController.close();
    await _statusController.close();
    await queueManager.dispose();
    await tenantScope.dispose();
  }
}
