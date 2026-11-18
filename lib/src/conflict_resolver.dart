import 'package:meta/meta.dart';

/// Available conflict resolution strategies.
enum ConflictStrategy {
  /// The payload with the more recent timestamp takes precedence.
  lastWriteWins,

  /// The server/remote state always takes precedence, discarding local edits.
  serverAuthoritative,

  /// The local/client state always takes precedence, overwriting remote edits.
  clientAuthoritative,

  /// A custom merge function is invoked to reconcile divergent states.
  customMerge;

  String toJson() => name;
}

/// Context passed to a [ConflictResolver] when local and remote entity versions diverge.
@immutable
class ConflictContext<T> {
  /// The unique identifier of the conflicting entity.
  final String entityId;

  /// The tenant workspace identifier.
  final String tenantId;

  /// The local state of the entity stored on this device.
  final T localEntity;

  /// The incoming remote/server state of the entity.
  final T remoteEntity;

  /// The timestamp of the local edit.
  final DateTime localTimestamp;

  /// The timestamp of the remote edit as determined by the server.
  final DateTime remoteTimestamp;

  /// Optional metadata associated with the entity or sync operation.
  final Map<String, dynamic> metadata;

  const ConflictContext({
    required this.entityId,
    required this.tenantId,
    required this.localEntity,
    required this.remoteEntity,
    required this.localTimestamp,
    required this.remoteTimestamp,
    this.metadata = const {},
  });

  /// True if the local version was updated strictly after the remote version.
  bool get isLocalNewer => localTimestamp.isAfter(remoteTimestamp);

  /// True if the remote version was updated strictly after the local version.
  bool get isRemoteNewer => remoteTimestamp.isAfter(localTimestamp);

  /// True if both timestamps are equal down to the millisecond.
  bool get areTimestampsEqual =>
      localTimestamp.isAtSameMomentAs(remoteTimestamp);

  @override
  String toString() =>
      'ConflictContext(entity: $entityId, tenant: $tenantId, localTime: $localTimestamp, remoteTime: $remoteTimestamp)';
}

/// The outcome of resolving a conflict between local and remote states.
@immutable
class ConflictResolution<T> {
  /// The reconciled entity state to be persisted locally.
  final T resolvedEntity;

  /// The strategy that was applied to resolve the conflict.
  final ConflictStrategy strategyUsed;

  /// Whether the resolved entity represents a modified state that must be pushed back to the server.
  ///
  /// For instance, if local state won or a custom merge synthesized a new version,
  /// this is set to `true` so the sync engine schedules a push back to the backend.
  final bool needsRemotePush;

  /// Optional explanation or audit trail for why this resolution was chosen.
  final String? details;

  const ConflictResolution({
    required this.resolvedEntity,
    required this.strategyUsed,
    this.needsRemotePush = false,
    this.details,
  });

  @override
  String toString() =>
      'ConflictResolution(strategy: ${strategyUsed.name}, needsPush: $needsRemotePush, details: $details)';
}

/// Functional callback definition for custom merge logic.
typedef ConflictMergeCallback<T> = ConflictResolution<T> Function(
    ConflictContext<T> context);

/// Contract and built-in implementations for resolving divergent entity states.
abstract class ConflictResolver<T> {
  const ConflictResolver();

  /// Resolves the divergence between local and remote states.
  ConflictResolution<T> resolve(ConflictContext<T> context);

  /// Creates a resolver implementing Last-Write-Wins based on timestamps.
  ///
  /// In the event of an exact timestamp tie, [tieBreaker] is consulted (defaults to server).
  factory ConflictResolver.lastWriteWins({
    ConflictStrategy tieBreaker = ConflictStrategy.serverAuthoritative,
  }) =>
      _LastWriteWinsResolver<T>(tieBreaker: tieBreaker);

  /// Creates a resolver where the server/remote version always wins.
  factory ConflictResolver.serverAuthoritative() =>
      _ServerAuthoritativeResolver<T>();

  /// Creates a resolver where the local/client version always wins.
  factory ConflictResolver.clientAuthoritative() =>
      _ClientAuthoritativeResolver<T>();

  /// Creates a resolver that delegates reconciliation to a custom callback.
  factory ConflictResolver.custom(ConflictMergeCallback<T> mergeCallback) =>
      _CustomCallbackResolver<T>(mergeCallback);
}

class _LastWriteWinsResolver<T> extends ConflictResolver<T> {
  final ConflictStrategy tieBreaker;

  const _LastWriteWinsResolver({
    this.tieBreaker = ConflictStrategy.serverAuthoritative,
  });

  @override
  ConflictResolution<T> resolve(ConflictContext<T> context) {
    if (context.isLocalNewer) {
      return ConflictResolution<T>(
        resolvedEntity: context.localEntity,
        strategyUsed: ConflictStrategy.lastWriteWins,
        needsRemotePush: true,
        details:
            'Local entity won because localTimestamp (${context.localTimestamp}) > remoteTimestamp (${context.remoteTimestamp}).',
      );
    } else if (context.isRemoteNewer) {
      return ConflictResolution<T>(
        resolvedEntity: context.remoteEntity,
        strategyUsed: ConflictStrategy.lastWriteWins,
        needsRemotePush: false,
        details:
            'Remote entity won because remoteTimestamp (${context.remoteTimestamp}) > localTimestamp (${context.localTimestamp}).',
      );
    } else {
      // Tie breaker
      if (tieBreaker == ConflictStrategy.clientAuthoritative) {
        return ConflictResolution<T>(
          resolvedEntity: context.localEntity,
          strategyUsed: ConflictStrategy.lastWriteWins,
          needsRemotePush: true,
          details:
              'Timestamp tie (${context.localTimestamp}): Local chosen by tieBreaker.',
        );
      } else {
        return ConflictResolution<T>(
          resolvedEntity: context.remoteEntity,
          strategyUsed: ConflictStrategy.lastWriteWins,
          needsRemotePush: false,
          details:
              'Timestamp tie (${context.localTimestamp}): Remote chosen by tieBreaker.',
        );
      }
    }
  }
}

class _ServerAuthoritativeResolver<T> extends ConflictResolver<T> {
  const _ServerAuthoritativeResolver();

  @override
  ConflictResolution<T> resolve(ConflictContext<T> context) {
    return ConflictResolution<T>(
      resolvedEntity: context.remoteEntity,
      strategyUsed: ConflictStrategy.serverAuthoritative,
      needsRemotePush: false,
      details: 'Server is authoritative: overwriting local modifications.',
    );
  }
}

class _ClientAuthoritativeResolver<T> extends ConflictResolver<T> {
  const _ClientAuthoritativeResolver();

  @override
  ConflictResolution<T> resolve(ConflictContext<T> context) {
    return ConflictResolution<T>(
      resolvedEntity: context.localEntity,
      strategyUsed: ConflictStrategy.clientAuthoritative,
      needsRemotePush: true,
      details:
          'Client is authoritative: persisting local edits and queuing server push.',
    );
  }
}

class _CustomCallbackResolver<T> extends ConflictResolver<T> {
  final ConflictMergeCallback<T> mergeCallback;

  const _CustomCallbackResolver(this.mergeCallback);

  @override
  ConflictResolution<T> resolve(ConflictContext<T> context) {
    return mergeCallback(context);
  }
}

/// Helper utility for merging raw JSON Maps field-by-field.
abstract final class MapConflictResolver {
  /// Merges [local] and [remote] maps. By default, keys present in both maps
  /// are taken from [local] if [preferLocal] is true, else from [remote].
  static Map<String, dynamic> mergeMaps({
    required Map<String, dynamic> local,
    required Map<String, dynamic> remote,
    bool preferLocal = false,
  }) {
    final merged = Map<String, dynamic>.from(preferLocal ? remote : local);
    final overlay = preferLocal ? local : remote;

    for (final entry in overlay.entries) {
      final key = entry.key;
      final value = entry.value;

      if (value != null) {
        if (value is Map<String, dynamic> &&
            merged[key] is Map<String, dynamic>) {
          merged[key] = mergeMaps(
            local: value,
            remote: merged[key] as Map<String, dynamic>,
            preferLocal: preferLocal,
          );
        } else {
          merged[key] = value;
        }
      }
    }

    return merged;
  }
}
