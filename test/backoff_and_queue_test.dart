import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  group('BackoffCalculator', () {
    test('returns zero delay for retryCount 0', () {
      const calc = BackoffCalculator(baseDelay: Duration(seconds: 1));
      final delay = calc.calculateBackoff(0);
      expect(delay, Duration.zero);
    });

    test('calculates deterministic exponential delay when jitterFactor is 0.0', () {
      const calc = BackoffCalculator(
        baseDelay: Duration(seconds: 1),
        multiplier: 2.0,
        maxDelay: Duration(seconds: 32),
        jitterFactor: 0.0,
      );

      // retry 1: 1 * 2^0 = 1s
      expect(calc.calculateBackoff(1), const Duration(seconds: 1));
      // retry 2: 1 * 2^1 = 2s
      expect(calc.calculateBackoff(2), const Duration(seconds: 2));
      // retry 3: 1 * 2^2 = 4s
      expect(calc.calculateBackoff(3), const Duration(seconds: 4));
      // retry 4: 1 * 2^3 = 8s
      expect(calc.calculateBackoff(4), const Duration(seconds: 8));
      // retry 5: 1 * 2^4 = 16s
      expect(calc.calculateBackoff(5), const Duration(seconds: 16));
      // retry 6: 1 * 2^5 = 32s (hits maxDelay)
      expect(calc.calculateBackoff(6), const Duration(seconds: 32));
      // retry 7: capped at maxDelay (32s)
      expect(calc.calculateBackoff(7), const Duration(seconds: 32));
    });

    test('jitter keeps delay strictly within [delay*(1-jitter), delay*(1+jitter)]', () {
      const calc = BackoffCalculator(
        baseDelay: Duration(seconds: 10),
        multiplier: 2.0,
        maxDelay: Duration(seconds: 100),
        jitterFactor: 0.20, // 20% jitter
      );

      // For retry 1 (raw delay = 10,000ms):
      // min = 8,000ms, max = 12,000ms
      final rng = Random(42);
      for (int i = 0; i < 50; i++) {
        final delay = calc.calculateBackoff(1, random: rng);
        expect(delay.inMilliseconds, greaterThanOrEqualTo(8000));
        expect(delay.inMilliseconds, lessThanOrEqualTo(12000));
      }
    });
  });

  group('SyncQueueManager - Execution & Retry Lifecycle', () {
    late InMemoryQueueStorage storage;
    late SyncQueueManager manager;
    final deadLetterOperations = <SyncOperation>[];

    setUp(() async {
      storage = InMemoryQueueStorage();
      deadLetterOperations.clear();
      manager = SyncQueueManager(
        storage: storage,
        backoffCalculator: const BackoffCalculator(
          baseDelay: Duration(milliseconds: 100),
          multiplier: 2.0,
          maxDelay: Duration(seconds: 5),
          jitterFactor: 0.0,
        ),
        onDeadLetter: (op) => deadLetterOperations.add(op),
      );
      await manager.init();
    });

    tearDown(() async {
      await manager.dispose();
    });

    test('enqueues and preserves FIFO order per tenant', () async {
      final op1 = SyncOperation(
        id: 'op_1',
        tenantId: 'tenant_a',
        endpoint: '/tasks',
        entityType: 'task',
        entityId: 't_1',
        payload: {'name': 'Task 1'},
        timestamp: DateTime.utc(2026, 1, 1, 10, 0),
      );
      final op2 = SyncOperation(
        id: 'op_2',
        tenantId: 'tenant_a',
        endpoint: '/tasks',
        entityType: 'task',
        entityId: 't_2',
        payload: {'name': 'Task 2'},
        timestamp: DateTime.utc(2026, 1, 1, 10, 1),
      );
      final opOtherTenant = SyncOperation(
        id: 'op_3',
        tenantId: 'tenant_b',
        endpoint: '/tasks',
        entityType: 'task',
        entityId: 't_3',
        payload: {'name': 'Task 3'},
        timestamp: DateTime.utc(2026, 1, 1, 10, 2),
      );

      await manager.enqueue(op1);
      await manager.enqueue(op2);
      await manager.enqueue(opOtherTenant);

      final readyTenantA = await manager.getReadyOperations('tenant_a');
      expect(readyTenantA.length, 2);
      expect(readyTenantA[0].id, 'op_1');
      expect(readyTenantA[1].id, 'op_2');

      final readyTenantB = await manager.getReadyOperations('tenant_b');
      expect(readyTenantB.length, 1);
      expect(readyTenantB[0].id, 'op_3');
    });

    test('failing an operation increments retryCount and computes nextAttemptAt', () async {
      final op = SyncOperation(
        id: 'op_retry',
        tenantId: 'tenant_a',
        endpoint: '/notes',
        entityType: 'note',
        entityId: 'n_1',
        maxRetries: 3,
      );
      await manager.enqueue(op);

      final failedOp = await manager.markFailed(
        op,
        error: '503 Service Unavailable',
      );

      expect(failedOp.retryCount, 1);
      expect(failedOp.status, SyncOperationStatus.failed);
      expect(failedOp.error, '503 Service Unavailable');
      expect(failedOp.nextAttemptAt, isNotNull);

      // Immediate check should not be ready if before nextAttemptAt
      final now = DateTime.now().toUtc();
      final beforeTime = now.subtract(const Duration(seconds: 1));
      expect(failedOp.isReadyForAttempt(beforeTime), isFalse);

      final afterTime = failedOp.nextAttemptAt!.add(const Duration(seconds: 1));
      expect(failedOp.isReadyForAttempt(afterTime), isTrue);
    });

    test('transitions to deadLetter when retryCount exceeds maxRetries', () async {
      final op = SyncOperation(
        id: 'op_dead',
        tenantId: 'tenant_a',
        endpoint: '/tasks',
        entityType: 'task',
        entityId: 't_dead',
        retryCount: 2,
        maxRetries: 3,
      );
      await manager.enqueue(op);

      final deadOp = await manager.markFailed(
        op,
        error: 'Fatal server crash',
      );

      expect(deadOp.retryCount, 3);
      expect(deadOp.status, SyncOperationStatus.deadLetter);
      expect(deadLetterOperations.length, 1);
      expect(deadLetterOperations.first.id, 'op_dead');

      // Dead letter operations must not be returned in getReadyOperations
      final ready = await manager.getReadyOperations('tenant_a');
      expect(ready, isEmpty);
    });

    test('isPermanent immediately routes to deadLetter', () async {
      final op = SyncOperation(
        id: 'op_bad_request',
        tenantId: 'tenant_a',
        endpoint: '/tasks',
        entityType: 'task',
        entityId: 't_bad',
        maxRetries: 5,
      );
      await manager.enqueue(op);

      final deadOp = await manager.markFailed(
        op,
        error: '400 Bad Request: Invalid payload structure',
        isPermanent: true,
      );

      expect(deadOp.status, SyncOperationStatus.deadLetter);
      expect(deadLetterOperations.length, 1);
    });
  });
}
