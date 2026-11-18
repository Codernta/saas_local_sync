import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  group('Tenant & Storage Security Checks', () {
    test('rejects tenant IDs attempting delimiter injection attacks', () {
      expect(
        () => ScopedKey.validateTenantId('tenant_a__ts__admin'),
        throwsA(isA<TenantSecurityException>()),
      );
    });

    test('rejects tenant IDs attempting directory traversal', () {
      expect(
        () => ScopedKey.validateTenantId('../etc/passwd'),
        throwsA(isA<TenantSecurityException>()),
      );
      expect(
        () => ScopedKey.validateTenantId('..\\windows\\system32'),
        throwsA(isA<TenantSecurityException>()),
      );
      expect(
        () => ScopedKey.validateTenantId('tenant/workspace'),
        throwsA(isA<TenantSecurityException>()),
      );
    });

    test('rejects null byte injection in tenant IDs and keys', () {
      expect(
        () => ScopedKey.validateTenantId('tenant\x00spoofed'),
        throwsA(isA<TenantSecurityException>()),
      );
      expect(
        () => ScopedKey.validateKey('key\x00poisoned'),
        throwsA(isA<TenantSecurityException>()),
      );
    });

    test('rejects storage keys containing internal delimiter', () {
      expect(
        () => ScopedKey.validateKey('user__ts__injected'),
        throwsA(isA<TenantSecurityException>()),
      );
    });

    test('accepts compliant, safe tenant IDs and keys', () {
      expect(
          () => ScopedKey.validateTenantId('acme-corp-123'), returnsNormally);
      expect(() => ScopedKey.validateTenantId('workspace_beta_99'),
          returnsNormally);
      expect(() => ScopedKey.validateTenantId('user.name@org.com'),
          returnsNormally);
      expect(() => ScopedKey.validateKey('task_12345'), returnsNormally);
      expect(() => ScopedKey.validateKey('settings-v2'), returnsNormally);
    });

    test('TenantScope enforces security validation on setTenant', () {
      final scope = TenantScope();
      expect(
        () => scope.setTenant('injected__ts__tenant'),
        throwsA(isA<TenantSecurityException>()),
      );
      expect(
        () => scope.setTenant('../malicious_path'),
        throwsA(isA<TenantSecurityException>()),
      );
      expect(() => scope.setTenant('valid-org-42'), returnsNormally);
    });
  });

  group('SyncOperation Security Validation', () {
    test('rejects dangerous URI schemes in endpoint', () {
      final jsOp = SyncOperation(
        tenantId: 'tenant_1',
        endpoint: 'javascript:stealCredentials()',
        entityType: 'task',
        entityId: '1',
      );
      expect(
        () => jsOp.validateSecurity(),
        throwsA(isA<TenantSecurityException>()),
      );

      final fileOp = SyncOperation(
        tenantId: 'tenant_1',
        endpoint: 'file:///etc/shadow',
        entityType: 'task',
        entityId: '1',
      );
      expect(
        () => fileOp.validateSecurity(),
        throwsA(isA<TenantSecurityException>()),
      );

      final dataOp = SyncOperation(
        tenantId: 'tenant_1',
        endpoint: 'data:text/html,<script>alert(1)</script>',
        entityType: 'task',
        entityId: '1',
      );
      expect(
        () => dataOp.validateSecurity(),
        throwsA(isA<TenantSecurityException>()),
      );
    });

    test('rejects payloads exceeding max security payload threshold', () {
      final hugeMap = <String, dynamic>{
        'blob':
            List.filled(5000, 'large-string-payload-fragment-exceeding-limit')
                .join(),
      };

      final op = SyncOperation(
        tenantId: 'tenant_1',
        endpoint: '/api/v1/sync',
        entityType: 'task',
        entityId: '1',
        payload: hugeMap,
      );

      // Verify validation fails when payload exceeds small threshold (e.g. 10KB)
      expect(
        () => op.validateSecurity(maxPayloadBytes: 10 * 1024),
        throwsA(isA<TenantSecurityException>()),
      );
    });
  });

  group('TenantSecurityChecker Isolation Audit', () {
    test('auditStoreIsolation verifies strict separation between two tenants',
        () async {
      final rawStore = InMemoryStoreAdapter<String>();
      await rawStore.init();

      final scope = TenantScope('tenant_alpha');
      final scopedStore = ScopedStoreWrapper<String>(
        adapter: rawStore,
        scope: scope,
      );

      final isIsolated =
          await TenantSecurityChecker.auditStoreIsolation<String>(
        store: scopedStore,
        tenantA: 'tenant_alpha',
        tenantB: 'tenant_beta',
        testValueA: 'Alpha Secret Data',
        testValueB: 'Beta Secret Data',
      );

      expect(isIsolated, isTrue);

      await scopedStore.dispose();
      await rawStore.dispose();
      await scope.dispose();
    });
  });
}
