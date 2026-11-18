import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  group('TenantScope & ScopedKey', () {
    test('ScopedKey formats and extracts raw keys correctly', () {
      final key = ScopedKey.format('tenant_alpha', 'user_123');
      expect(key, 't_tenant_alpha__ts__user_123');

      expect(ScopedKey.belongsToTenant(key, 'tenant_alpha'), isTrue);
      expect(ScopedKey.belongsToTenant(key, 'tenant_beta'), isFalse);

      expect(ScopedKey.extractRawKey(key, 'tenant_alpha'), 'user_123');
      expect(ScopedKey.extractRawKey(key, 'tenant_beta'), isNull);

      expect(ScopedKey.extractTenantId(key), 'tenant_alpha');
    });

    test('ScopedKey throws on empty tenant', () {
      expect(() => ScopedKey.format('', 'key'), throwsArgumentError);
    });

    test('TenantScope enforces active tenant state and change stream', () async {
      final scope = TenantScope();
      expect(scope.hasActiveTenant, isFalse);
      expect(() => scope.activeTenantId, throwsA(isA<NoActiveTenantException>()));

      final tenantEmissions = <String?>[];
      final sub = scope.onTenantChanged.listen(tenantEmissions.add);

      scope.setTenant('tenant_1');
      expect(scope.hasActiveTenant, isTrue);
      expect(scope.activeTenantId, 'tenant_1');

      scope.setTenant('tenant_2');
      expect(scope.activeTenantId, 'tenant_2');

      scope.clearTenant();
      expect(scope.hasActiveTenant, isFalse);

      await Future.delayed(Duration.zero);
      expect(tenantEmissions, equals(['tenant_1', 'tenant_2', null]));

      await sub.cancel();
      await scope.dispose();
    });

    test('ensureActiveTenant validates matching tenant', () {
      final scope = TenantScope('org_a');
      expect(() => scope.ensureActiveTenant('org_a'), returnsNormally);
      expect(
        () => scope.ensureActiveTenant('org_b'),
        throwsA(isA<TenantMismatchException>()),
      );
    });
  });

  group('ScopedStoreWrapper - Strict Multi-Tenant Isolation', () {
    late InMemoryStoreAdapter<String> rawStore;
    late TenantScope scope;
    late ScopedStoreWrapper<String> scopedStore;

    setUp(() async {
      rawStore = InMemoryStoreAdapter<String>();
      scope = TenantScope('tenant_1');
      scopedStore = ScopedStoreWrapper<String>(
        adapter: rawStore,
        scope: scope,
      );
      await rawStore.init();
    });

    tearDown(() async {
      await scopedStore.dispose();
      await rawStore.dispose();
      await scope.dispose();
    });

    test('isolates data between tenants with zero leakage', () async {
      // 1. Populate data under tenant_1
      await scopedStore.put('doc_1', 'Tenant 1 Document');
      await scopedStore.put('doc_2', 'Tenant 1 Spreadsheet');

      final t1Docs = await scopedStore.getAll();
      expect(t1Docs.length, 2);
      expect(t1Docs['doc_1'], 'Tenant 1 Document');
      expect(t1Docs['doc_2'], 'Tenant 1 Spreadsheet');

      // 2. Switch to tenant_2
      scope.setTenant('tenant_2');

      // Verify tenant_2 sees zero records
      final t2EmptyDocs = await scopedStore.getAll();
      expect(t2EmptyDocs, isEmpty);
      expect(await scopedStore.get('doc_1'), isNull);

      // 3. Populate data under tenant_2 with matching raw keys
      await scopedStore.put('doc_1', 'Tenant 2 Document with same ID');
      final t2Docs = await scopedStore.getAll();
      expect(t2Docs.length, 1);
      expect(t2Docs['doc_1'], 'Tenant 2 Document with same ID');

      // 4. Switch back to tenant_1 and verify tenant_1 data is uncorrupted
      scope.setTenant('tenant_1');
      final t1DocsAfter = await scopedStore.getAll();
      expect(t1DocsAfter.length, 2);
      expect(t1DocsAfter['doc_1'], 'Tenant 1 Document');
      expect(t1DocsAfter['doc_2'], 'Tenant 1 Spreadsheet');
    });

    test('clear() only removes records belonging to active tenant', () async {
      // Put records in tenant_1
      scope.setTenant('tenant_1');
      await scopedStore.put('item_a', 'Data A1');
      await scopedStore.put('item_b', 'Data B1');

      // Put records in tenant_2
      scope.setTenant('tenant_2');
      await scopedStore.put('item_a', 'Data A2');
      await scopedStore.put('item_c', 'Data C2');

      // Clear tenant_2
      await scopedStore.clear();

      // Tenant 2 must now be empty
      expect(await scopedStore.getAll(), isEmpty);

      // Tenant 1 must still have its data intact
      scope.setTenant('tenant_1');
      final t1Items = await scopedStore.getAll();
      expect(t1Items.length, 2);
      expect(t1Items['item_a'], 'Data A1');
      expect(t1Items['item_b'], 'Data B1');
    });

    test('watchAll emits scoped changes and updates on tenant switch', () async {
      scope.setTenant('tenant_1');
      final emissions = <Map<String, String>>[];
      final sub = scopedStore.watchAll().listen(emissions.add);

      await Future.delayed(const Duration(milliseconds: 10));
      await scopedStore.put('k1', 'v1');
      await Future.delayed(const Duration(milliseconds: 10));

      scope.setTenant('tenant_2');
      await Future.delayed(const Duration(milliseconds: 10));
      await scopedStore.put('k2', 'v2');
      await Future.delayed(const Duration(milliseconds: 10));

      expect(emissions.isNotEmpty, isTrue);
      // Last emission should be tenant_2 data only
      expect(emissions.last, equals({'k2': 'v2'}));

      await sub.cancel();
    });
  });
}
