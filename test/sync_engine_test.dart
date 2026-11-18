import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

class TestTask implements SyncEntity {
  @override
  final String id;
  @override
  final String tenantId;
  final String title;
  final bool isCompleted;
  @override
  final DateTime updatedAt;
  @override
  final bool isDeleted;
  @override
  final SyncState syncState;

  TestTask({
    required this.id,
    required this.tenantId,
    required this.title,
    this.isCompleted = false,
    required this.updatedAt,
    this.isDeleted = false,
    this.syncState = SyncState.synced,
  });

  TestTask copyWith({
    String? id,
    String? tenantId,
    String? title,
    bool? isCompleted,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return TestTask(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      title: title ?? this.title,
      isCompleted: isCompleted ?? this.isCompleted,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'tenantId': tenantId,
        'title': title,
        'isCompleted': isCompleted,
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
        'syncState': syncState.toJson(),
      };

  factory TestTask.fromJson(Map<String, dynamic> json) => TestTask(
        id: json['id'] as String,
        tenantId: json['tenantId'] as String,
        title: json['title'] as String,
        isCompleted: json['isCompleted'] as bool? ?? false,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        isDeleted: json['isDeleted'] as bool? ?? false,
        syncState: SyncState.fromJson(json['syncState'] as String? ?? 'synced'),
      );
}

void main() {
  group('SyncEngine & SyncRepository - End-to-End Orchestration', () {
    late TenantScope tenantScope;
    late InMemoryStoreAdapter<TestTask> rawStore;
    late ScopedStoreWrapper<TestTask> scopedStore;
    late InMemoryQueueStorage queueStorage;
    late SyncQueueManager queueManager;
    late PluggableConnectivityMonitor connectivity;
    late MockRemoteTransport transport;
    late SyncEngine engine;
    late SyncRepository<TestTask, String> taskRepo;

    setUp(() async {
      tenantScope = TenantScope('tenant_alpha');
      rawStore = InMemoryStoreAdapter<TestTask>();
      await rawStore.init();

      scopedStore = ScopedStoreWrapper<TestTask>(
        adapter: rawStore,
        scope: tenantScope,
      );

      queueStorage = InMemoryQueueStorage();
      queueManager = SyncQueueManager(
        storage: queueStorage,
        backoffCalculator: const BackoffCalculator(jitterFactor: 0.0),
      );

      connectivity = PluggableConnectivityMonitor(initialOnline: false);
      transport = MockRemoteTransport(simulatedLatency: Duration.zero);

      engine = SyncEngine(
        tenantScope: tenantScope,
        queueManager: queueManager,
        connectivity: connectivity,
        transport: transport,
        options: const SyncEngineOptions(
          autoSyncOnOnline: true,
          periodicSyncInterval: null, // manual in test
        ),
      );

      taskRepo = SyncRepository<TestTask, String>(
        entityType: 'task',
        endpoint: '/api/v1/tasks',
        store: scopedStore,
        queueManager: queueManager,
        fromJson: TestTask.fromJson,
        toJson: (t) => t.toJson(),
        withSyncState: (entity, state, time) => entity.copyWith(
          syncState: state,
          updatedAt: time,
        ),
      );

      engine.registerRepository(taskRepo);
      await engine.initialize();
    });

    tearDown(() async {
      await engine.dispose();
      await scopedStore.dispose();
      await rawStore.dispose();
    });

    test('optimistic offline mutation followed by online background flush', () async {
      // 1. Initially offline
      expect(engine.currentState.isOnline, isFalse);
      expect(engine.currentStatus, SyncStatus.offline);

      // 2. Perform optimistic write while offline
      final task = TestTask(
        id: 'task_1',
        tenantId: 'tenant_alpha',
        title: 'Draft Marketing Plan',
        updatedAt: DateTime.now().toUtc(),
      );
      await taskRepo.save(task);

      // Verify task exists immediately in local cache with pendingCreation
      final localBeforeOnline = await taskRepo.findById('task_1');
      expect(localBeforeOnline, isNotNull);
      expect(localBeforeOnline!.title, 'Draft Marketing Plan');
      expect(localBeforeOnline.syncState, SyncState.pendingCreation);

      // Verify queue has 1 pending operation
      final pendingCount = await queueManager.getPendingCount('tenant_alpha');
      expect(pendingCount, 1);

      // Remote server does NOT have the task yet
      expect(transport.getServerRecord('tenant_alpha', 'task_1'), isNull);

      // 3. Simulate Device Coming Back Online
      connectivity.setOnline(true);
      await Future.delayed(const Duration(milliseconds: 50));

      // 4. Verify queue was automatically flushed
      final pendingAfterSync = await queueManager.getPendingCount('tenant_alpha');
      expect(pendingAfterSync, 0);

      // Verify remote mock server now holds the record
      final serverRecord = transport.getServerRecord('tenant_alpha', 'task_1');
      expect(serverRecord, isNotNull);
      expect(serverRecord?['title'], 'Draft Marketing Plan');

      // Verify local entity status transitioned to synced!
      final localAfterSync = await taskRepo.findById('task_1');
      expect(localAfterSync!.syncState, SyncState.synced);
      expect(engine.currentStatus, SyncStatus.synced);
    });

    test('handles 409 conflict during push and resolves via ConflictResolver', () async {
      connectivity.setOnline(true);
      await Future.delayed(const Duration(milliseconds: 20));

      // 1. Create task locally
      final task = TestTask(
        id: 'task_conflict',
        tenantId: 'tenant_alpha',
        title: 'Initial Title',
        updatedAt: DateTime.utc(2026, 6, 1, 10, 0),
      );
      await taskRepo.save(task);
      await engine.sync();

      // Verify initial state is synced
      expect((await taskRepo.findById('task_conflict'))?.syncState, SyncState.synced);

      // 2. Arm simulated conflict on transport with newer remote data
      transport.injectServerChange('tenant_alpha', 'task_conflict', {
        'id': 'task_conflict',
        'tenantId': 'tenant_alpha',
        'title': 'Remote Cloud Updated Title',
        'isCompleted': true,
        'updatedAt': DateTime.utc(2026, 6, 1, 12, 0).toIso8601String(),
        'isDeleted': false,
        'syncState': 'synced',
      });
      transport.triggerConflictOnNextPush('task_conflict');

      // 3. Make an offline local edit with an older timestamp
      connectivity.setOnline(false);
      final editedLocal = task.copyWith(
        title: 'Local Slower Edit',
        updatedAt: DateTime.utc(2026, 6, 1, 11, 0),
      );
      await taskRepo.save(editedLocal);

      // 4. Bring device online to flush queue
      connectivity.setOnline(true);
      await Future.delayed(const Duration(milliseconds: 50));

      // 5. Verify conflict was resolved using Last-Write-Wins:
      // Remote timestamp (12:00) > Local timestamp (11:00) -> Remote wins!
      final resolved = await taskRepo.findById('task_conflict');
      expect(resolved, isNotNull);
      expect(resolved!.title, 'Remote Cloud Updated Title');
      expect(resolved.isCompleted, isTrue);
      expect(resolved.syncState, SyncState.conflictResolved);
      expect(await queueManager.getPendingCount('tenant_alpha'), 0);
    });

    test('switching tenant isolates queue flushing strictly to active tenant', () async {
      connectivity.setOnline(false);

      // Add task for tenant_alpha
      await taskRepo.save(TestTask(
        id: 't_alpha_1',
        tenantId: 'tenant_alpha',
        title: 'Alpha Secret Task',
        updatedAt: DateTime.now().toUtc(),
      ));

      // Switch to tenant_beta
      engine.switchTenant('tenant_beta');

      // Add task for tenant_beta
      final betaTask = TestTask(
        id: 't_beta_1',
        tenantId: 'tenant_beta',
        title: 'Beta Secret Task',
        updatedAt: DateTime.now().toUtc(),
      );
      await taskRepo.save(betaTask);

      // Bring online: only tenant_beta should flush!
      connectivity.setOnline(true);
      await Future.delayed(const Duration(milliseconds: 50));

      // Tenant Beta must be synced
      expect(transport.getServerRecord('tenant_beta', 't_beta_1'), isNotNull);

      // Tenant Alpha must NOT have synced yet because it wasn't the active tenant!
      expect(transport.getServerRecord('tenant_alpha', 't_alpha_1'), isNull);
      expect(await queueManager.getPendingCount('tenant_alpha'), 1);

      // Now switch back to tenant_alpha while online: should immediately trigger flush
      engine.switchTenant('tenant_alpha');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(transport.getServerRecord('tenant_alpha', 't_alpha_1'), isNotNull);
      expect(await queueManager.getPendingCount('tenant_alpha'), 0);
    });
  });
}
