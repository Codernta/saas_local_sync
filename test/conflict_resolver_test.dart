import 'package:flutter_test/flutter_test.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  group('ConflictResolver - Last Write Wins (LWW)', () {
    final resolver = ConflictResolver<Map<String, dynamic>>.lastWriteWins();

    test('picks local when localTimestamp > remoteTimestamp', () {
      final local = {'id': '1', 'title': 'Local Edit', 'tags': ['urgent']};
      final remote = {'id': '1', 'title': 'Remote Edit', 'tags': ['later']};

      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '1',
        tenantId: 'tenant_1',
        localEntity: local,
        remoteEntity: remote,
        localTimestamp: DateTime.utc(2026, 6, 1, 14, 0),
        remoteTimestamp: DateTime.utc(2026, 6, 1, 13, 0),
      );

      final resolution = resolver.resolve(context);
      expect(resolution.strategyUsed, ConflictStrategy.lastWriteWins);
      expect(resolution.resolvedEntity['title'], 'Local Edit');
      expect(resolution.needsRemotePush, isTrue);
    });

    test('picks remote when remoteTimestamp > localTimestamp', () {
      final local = {'id': '1', 'title': 'Local Edit'};
      final remote = {'id': '1', 'title': 'Remote Edit'};

      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '1',
        tenantId: 'tenant_1',
        localEntity: local,
        remoteEntity: remote,
        localTimestamp: DateTime.utc(2026, 6, 1, 12, 0),
        remoteTimestamp: DateTime.utc(2026, 6, 1, 15, 0),
      );

      final resolution = resolver.resolve(context);
      expect(resolution.strategyUsed, ConflictStrategy.lastWriteWins);
      expect(resolution.resolvedEntity['title'], 'Remote Edit');
      expect(resolution.needsRemotePush, isFalse);
    });

    test('resolves tie using default serverAuthoritative tieBreaker', () {
      final timestamp = DateTime.utc(2026, 6, 1, 12, 0);
      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '1',
        tenantId: 'tenant_1',
        localEntity: {'id': '1', 'title': 'Local'},
        remoteEntity: {'id': '1', 'title': 'Remote'},
        localTimestamp: timestamp,
        remoteTimestamp: timestamp,
      );

      final resolution = resolver.resolve(context);
      expect(resolution.resolvedEntity['title'], 'Remote');
      expect(resolution.needsRemotePush, isFalse);
    });

    test('resolves tie using clientAuthoritative tieBreaker when configured', () {
      final clientTieResolver = ConflictResolver<Map<String, dynamic>>.lastWriteWins(
        tieBreaker: ConflictStrategy.clientAuthoritative,
      );
      final timestamp = DateTime.utc(2026, 6, 1, 12, 0);
      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '1',
        tenantId: 'tenant_1',
        localEntity: {'id': '1', 'title': 'Local'},
        remoteEntity: {'id': '1', 'title': 'Remote'},
        localTimestamp: timestamp,
        remoteTimestamp: timestamp,
      );

      final resolution = clientTieResolver.resolve(context);
      expect(resolution.resolvedEntity['title'], 'Local');
      expect(resolution.needsRemotePush, isTrue);
    });
  });

  group('ConflictResolver - Server Authoritative & Client Authoritative', () {
    test('Server authoritative always accepts remote state', () {
      final resolver =
          ConflictResolver<Map<String, dynamic>>.serverAuthoritative();
      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '10',
        tenantId: 'tenant_1',
        localEntity: {'title': 'Draft Local'},
        remoteEntity: {'title': 'Published Remote'},
        localTimestamp: DateTime.utc(2026, 6, 2),
        remoteTimestamp: DateTime.utc(2026, 6, 1),
      );

      final resolution = resolver.resolve(context);
      expect(resolution.strategyUsed, ConflictStrategy.serverAuthoritative);
      expect(resolution.resolvedEntity['title'], 'Published Remote');
      expect(resolution.needsRemotePush, isFalse);
    });

    test('Client authoritative always accepts local state and requests push', () {
      final resolver =
          ConflictResolver<Map<String, dynamic>>.clientAuthoritative();
      final context = ConflictContext<Map<String, dynamic>>(
        entityId: '10',
        tenantId: 'tenant_1',
        localEntity: {'title': 'My Important Notes'},
        remoteEntity: {'title': 'Cloud Stale Version'},
        localTimestamp: DateTime.utc(2026, 6, 1),
        remoteTimestamp: DateTime.utc(2026, 6, 2),
      );

      final resolution = resolver.resolve(context);
      expect(resolution.strategyUsed, ConflictStrategy.clientAuthoritative);
      expect(resolution.resolvedEntity['title'], 'My Important Notes');
      expect(resolution.needsRemotePush, isTrue);
    });
  });

  group('ConflictResolver - Custom Merge', () {
    test('merges local and remote fields with custom business logic', () {
      final customResolver = ConflictResolver<Map<String, dynamic>>.custom((context) {
        final local = context.localEntity;
        final remote = context.remoteEntity;

        final merged = <String, dynamic>{
          'id': context.entityId,
          'tenantId': context.tenantId,
          // Custom merge: concatenate titles with conflict banner
          'title': '${local['title']} (Merged with: ${remote['title']})',
          // Merge lists of tags
          'tags': <String>{
            ...List<String>.from(local['tags'] as List? ?? []),
            ...List<String>.from(remote['tags'] as List? ?? []),
          }.toList(),
          'completed': local['completed'] == true || remote['completed'] == true,
        };

        return ConflictResolution<Map<String, dynamic>>(
          resolvedEntity: merged,
          strategyUsed: ConflictStrategy.customMerge,
          needsRemotePush: true,
          details: 'Merged conflicting task properties.',
        );
      });

      final context = ConflictContext<Map<String, dynamic>>(
        entityId: 'item_1',
        tenantId: 'tenant_sales',
        localEntity: {
          'id': 'item_1',
          'title': 'Local offline changes',
          'tags': ['sales', 'q3'],
          'completed': false,
        },
        remoteEntity: {
          'id': 'item_1',
          'title': 'Remote web changes',
          'tags': ['sales', 'approved'],
          'completed': true,
        },
        localTimestamp: DateTime.now().toUtc(),
        remoteTimestamp: DateTime.now().toUtc(),
      );

      final resolution = customResolver.resolve(context);
      expect(resolution.strategyUsed, ConflictStrategy.customMerge);
      expect(resolution.needsRemotePush, isTrue);
      expect(resolution.resolvedEntity['title'],
          'Local offline changes (Merged with: Remote web changes)');
      expect(resolution.resolvedEntity['tags'],
          containsAll(['sales', 'q3', 'approved']));
      expect(resolution.resolvedEntity['completed'], isTrue);
    });
  });

  group('MapConflictResolver', () {
    test('merges nested maps accurately', () {
      final local = {
        'title': 'Local Task',
        'metadata': {'priority': 'high', 'color': 'red'},
      };
      final remote = {
        'title': 'Remote Task',
        'metadata': {'priority': 'low', 'assignedTo': 'Alice'},
      };

      final mergedPreferLocal = MapConflictResolver.mergeMaps(
        local: local,
        remote: remote,
        preferLocal: true,
      );

      expect(mergedPreferLocal['title'], 'Local Task');
      final meta = mergedPreferLocal['metadata'] as Map<String, dynamic>;
      expect(meta['priority'], 'high');
      expect(meta['color'], 'red');
      expect(meta['assignedTo'], 'Alice');
    });
  });
}
