import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  late Directory tempDir;
  late File queueFile;
  late File storeFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('saas_sync_test_');
    queueFile = File('${tempDir.path}/sync_queue.json');
    storeFile = File('${tempDir.path}/local_store.json');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FileJsonQueueStorage - Real Disk Persistence & Crash Recovery', () {
    test(
        'persists queue to disk and recovers all operations after simulated restart',
        () async {
      // 1. App Session 1: Create storage and enqueue operations
      final storageSession1 = FileJsonQueueStorage(file: queueFile);
      final managerSession1 = SyncQueueManager(storage: storageSession1);
      await managerSession1.init();

      final op1 = SyncOperation(
        id: 'op_session1_1',
        tenantId: 'workspace_a',
        endpoint: '/api/v1/projects',
        entityType: 'project',
        entityId: 'proj_1',
        payload: {'name': 'Project 1'},
        timestamp: DateTime.utc(2026, 1, 1, 10, 0),
      );

      final op2 = SyncOperation(
        id: 'op_session1_2',
        tenantId: 'workspace_a',
        endpoint: '/api/v1/projects',
        entityType: 'project',
        entityId: 'proj_2',
        payload: {'name': 'Project 2'},
        timestamp: DateTime.utc(2026, 1, 1, 10, 5),
      );

      await managerSession1.enqueue(op1);
      await managerSession1.enqueue(op2);

      // Simulate op2 being mid-network-transmission (inFlight) when app suddenly terminates
      await managerSession1.markInFlight(op2);

      // Verify file physically exists on disk and is non-empty
      expect(await queueFile.exists(), isTrue);
      final rawDiskContent = await queueFile.readAsString();
      expect(rawDiskContent, contains('op_session1_1'));
      expect(rawDiskContent, contains('op_session1_2'));

      // 2. Simulate App Termination / Process Kill
      await managerSession1.dispose();

      // 3. App Session 2: Fresh app bootup reading from same disk file
      final storageSession2 = FileJsonQueueStorage(file: queueFile);
      final managerSession2 = SyncQueueManager(storage: storageSession2);
      await managerSession2.init();

      // Verify operations are completely recovered
      final pendingOps =
          await managerSession2.getOperationsForTenant('workspace_a');
      expect(pendingOps.length, 2);

      final recoveredOp1 =
          pendingOps.firstWhere((o) => o.id == 'op_session1_1');
      expect(recoveredOp1.payload?['name'], 'Project 1');
      expect(recoveredOp1.status, SyncOperationStatus.pending);

      final recoveredOp2 =
          pendingOps.firstWhere((o) => o.id == 'op_session1_2');
      expect(recoveredOp2.payload?['name'], 'Project 2');
      // In-flight operation at crash time MUST safely reset to pending
      expect(recoveredOp2.status, SyncOperationStatus.pending);

      // 4. Mark one completed and verify disk updates
      await managerSession2.markCompleted('op_session1_1');

      final remaining =
          await managerSession2.getOperationsForTenant('workspace_a');
      expect(remaining.length, 1);
      expect(remaining.first.id, 'op_session1_2');

      final updatedDiskContent = await queueFile.readAsString();
      expect(updatedDiskContent, isNot(contains('op_session1_1')));
      expect(updatedDiskContent, contains('op_session1_2'));

      await managerSession2.dispose();
    });
  });

  group('FileJsonStoreAdapter - Entity Disk Persistence', () {
    test('persists entities to disk and recovers after app restart', () async {
      // 1. Session 1: write data
      final storeSession1 = FileJsonStoreAdapter<Map<String, dynamic>>(
        file: storeFile,
        fromJson: (json) => json,
        toJson: (val) => val,
      );
      await storeSession1.init();

      await storeSession1
          .put('key_1', {'title': 'Persistent Title', 'count': 42});
      await storeSession1.dispose();

      // Verify file exists
      expect(await storeFile.exists(), isTrue);

      // 2. Session 2: fresh instance
      final storeSession2 = FileJsonStoreAdapter<Map<String, dynamic>>(
        file: storeFile,
        fromJson: (json) => json,
        toJson: (val) => val,
      );
      await storeSession2.init();

      final record = await storeSession2.get('key_1');
      expect(record, isNotNull);
      expect(record?['title'], 'Persistent Title');
      expect(record?['count'], 42);

      await storeSession2.dispose();
    });
  });
}
