import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'tenant_scope.dart';

/// The type of mutation operation being performed.
enum SyncOperationType {
  create,
  update,
  delete,
  custom;

  String toJson() => name;
  static SyncOperationType fromJson(String value) {
    return SyncOperationType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SyncOperationType.custom,
    );
  }
}

/// The execution status of a queued sync operation.
enum SyncOperationStatus {
  pending,
  inFlight,
  failed,
  deadLetter,
  completed;

  String toJson() => name;
  static SyncOperationStatus fromJson(String value) {
    return SyncOperationStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => SyncOperationStatus.pending,
    );
  }
}

/// Represents a queued mutation intended for background synchronization.
@immutable
class SyncOperation {
  final String id;
  final String tenantId;
  final String endpoint;
  final Map<String, dynamic>? payload;
  final DateTime timestamp;
  final int retryCount;
  final int maxRetries;
  final String entityType;
  final String entityId;
  final SyncOperationType operationType;
  final SyncOperationStatus status;
  final DateTime? lastAttemptAt;
  final DateTime? nextAttemptAt;
  final String? error;
  final Map<String, dynamic>? metadata;

  SyncOperation({
    String? id,
    required this.tenantId,
    required this.endpoint,
    this.payload,
    DateTime? timestamp,
    this.retryCount = 0,
    this.maxRetries = 5,
    required this.entityType,
    required this.entityId,
    this.operationType = SyncOperationType.update,
    this.status = SyncOperationStatus.pending,
    this.lastAttemptAt,
    this.nextAttemptAt,
    this.error,
    this.metadata,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now().toUtc();

  /// Whether this operation is ready to be retried based on [nextAttemptAt].
  bool isReadyForAttempt([DateTime? now]) {
    if (status != SyncOperationStatus.pending &&
        status != SyncOperationStatus.failed) {
      return false;
    }
    if (nextAttemptAt == null) return true;
    final current = now ?? DateTime.now().toUtc();
    return current.isAfter(nextAttemptAt!) ||
        current.isAtSameMomentAs(nextAttemptAt!);
  }

  /// Whether this operation has exceeded its retry budget and is dead-lettered.
  bool get isDeadLetter =>
      status == SyncOperationStatus.deadLetter || retryCount >= maxRetries;

  /// Performs security and sanity checks on this operation.
  ///
  /// Enforces tenant ID security, verifies endpoint safety (blocking disallowed schemes like `javascript:` or `file:`),
  /// and protects against memory exhaustion via [maxPayloadBytes].
  ///
  /// Throws [TenantSecurityException] if validation fails.
  void validateSecurity({int maxPayloadBytes = 5 * 1024 * 1024}) {
    ScopedKey.validateTenantId(tenantId);
    if (id.isEmpty || id.contains('\x00')) {
      throw TenantSecurityException(
          'Operation ID is invalid or contains null bytes');
    }
    if (endpoint.isEmpty || endpoint.contains('\x00')) {
      throw TenantSecurityException(
          'Endpoint cannot be empty or contain null bytes');
    }

    final lowerEndpoint = endpoint.toLowerCase().trim();
    if (lowerEndpoint.startsWith('javascript:') ||
        lowerEndpoint.startsWith('data:') ||
        lowerEndpoint.startsWith('file:')) {
      throw TenantSecurityException(
          'Endpoint uses disallowed protocol: $endpoint', endpoint);
    }

    if (payload != null) {
      final jsonStr = jsonEncode(payload);
      if (jsonStr.length > maxPayloadBytes) {
        throw TenantSecurityException(
          'Payload size exceeds maximum allowed security limit ($maxPayloadBytes bytes)',
        );
      }
    }
  }

  SyncOperation copyWith({
    String? id,
    String? tenantId,
    String? endpoint,
    Map<String, dynamic>? payload,
    DateTime? timestamp,
    int? retryCount,
    int? maxRetries,
    String? entityType,
    String? entityId,
    SyncOperationType? operationType,
    SyncOperationStatus? status,
    DateTime? lastAttemptAt,
    DateTime? nextAttemptAt,
    String? error,
    Map<String, dynamic>? metadata,
  }) {
    return SyncOperation(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      endpoint: endpoint ?? this.endpoint,
      payload: payload ?? this.payload,
      timestamp: timestamp ?? this.timestamp,
      retryCount: retryCount ?? this.retryCount,
      maxRetries: maxRetries ?? this.maxRetries,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      operationType: operationType ?? this.operationType,
      status: status ?? this.status,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      error: error ?? this.error,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tenantId': tenantId,
      'endpoint': endpoint,
      'payload': payload,
      'timestamp': timestamp.toIso8601String(),
      'retryCount': retryCount,
      'maxRetries': maxRetries,
      'entityType': entityType,
      'entityId': entityId,
      'operationType': operationType.toJson(),
      'status': status.toJson(),
      'lastAttemptAt': lastAttemptAt?.toIso8601String(),
      'nextAttemptAt': nextAttemptAt?.toIso8601String(),
      'error': error,
      'metadata': metadata,
    };
  }

  factory SyncOperation.fromJson(Map<String, dynamic> json) {
    return SyncOperation(
      id: json['id'] as String,
      tenantId: json['tenantId'] as String,
      endpoint: json['endpoint'] as String,
      payload: json['payload'] != null
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : null,
      timestamp: DateTime.parse(json['timestamp'] as String),
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
      maxRetries: (json['maxRetries'] as num?)?.toInt() ?? 5,
      entityType: json['entityType'] as String? ?? 'entity',
      entityId: json['entityId'] as String? ?? '',
      operationType: SyncOperationType.fromJson(
          json['operationType'] as String? ?? 'update'),
      status:
          SyncOperationStatus.fromJson(json['status'] as String? ?? 'pending'),
      lastAttemptAt: json['lastAttemptAt'] != null
          ? DateTime.parse(json['lastAttemptAt'] as String)
          : null,
      nextAttemptAt: json['nextAttemptAt'] != null
          ? DateTime.parse(json['nextAttemptAt'] as String)
          : null,
      error: json['error'] as String?,
      metadata: json['metadata'] != null
          ? Map<String, dynamic>.from(json['metadata'] as Map)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncOperation &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'SyncOperation(id: $id, tenant: $tenantId, entity: $entityType/$entityId, op: ${operationType.name}, status: ${status.name}, retries: $retryCount/$maxRetries)';
}

/// Calculates exponential backoff with full or decorrelated jitter.
///
/// Prevents thundering herds by dispersing retry intervals across nodes.
class BackoffCalculator {
  /// The initial backoff delay duration applied on the first retry attempt.
  final Duration baseDelay;

  /// The ceiling duration capping the maximum backoff interval.
  final Duration maxDelay;

  /// The rate of exponential expansion applied across consecutive retries.
  final double multiplier;

  /// The jitter factor scaling the randomized window around the base delay.
  final double jitterFactor;

  /// Creates a [BackoffCalculator] with customizable exponential backoff and jitter parameters.
  const BackoffCalculator({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.multiplier = 2.0,
    this.jitterFactor = 0.25,
  }) : assert(jitterFactor >= 0.0 && jitterFactor <= 1.0,
            'jitterFactor must be between 0.0 and 1.0');

  /// Calculates the next backoff duration for a given [retryCount].
  ///
  /// Uses exponential expansion capped at [maxDelay] and scaled with [jitterFactor].
  Duration calculateBackoff(int retryCount, {Random? random}) {
    if (retryCount <= 0) {
      return Duration.zero;
    }

    final rng = random ?? Random();

    // Exponential delay in milliseconds: base * (multiplier ^ (retryCount - 1))
    final expMultiplier = pow(multiplier, retryCount - 1).toDouble();
    final rawDelayMs = (baseDelay.inMilliseconds * expMultiplier)
        .clamp(0, maxDelay.inMilliseconds)
        .toDouble();

    if (jitterFactor == 0.0) {
      return Duration(milliseconds: rawDelayMs.round());
    }

    // Jitter range: [rawDelay * (1 - jitter), rawDelay * (1 + jitter)]
    final minJitter = 1.0 - jitterFactor;
    final jitterSpread = 2.0 * jitterFactor;
    final randomizedFactor = minJitter + (rng.nextDouble() * jitterSpread);
    final jitteredDelayMs = (rawDelayMs * randomizedFactor).clamp(
      0.0,
      (maxDelay.inMilliseconds * (1.0 + jitterFactor)),
    );

    return Duration(milliseconds: jitteredDelayMs.round());
  }
}

/// Abstract contract for persisting sync operations to local durable storage.
abstract class SyncQueueStorage {
  Future<void> init();
  Future<void> save(SyncOperation operation);
  Future<void> saveBatch(List<SyncOperation> operations);
  Future<void> remove(String operationId);
  Future<SyncOperation?> getById(String operationId);
  Future<List<SyncOperation>> getPendingForTenant(String tenantId);
  Future<List<SyncOperation>> getAllForTenant(String tenantId);
  Future<void> clearForTenant(String tenantId);
  Future<void> clearAll();
  Future<void> dispose();
}

/// In-memory queue storage implementation.
class InMemoryQueueStorage implements SyncQueueStorage {
  final Map<String, SyncOperation> _storage = {};

  @override
  Future<void> init() async {}

  @override
  Future<void> save(SyncOperation operation) async {
    _storage[operation.id] = operation;
  }

  @override
  Future<void> saveBatch(List<SyncOperation> operations) async {
    for (final op in operations) {
      _storage[op.id] = op;
    }
  }

  @override
  Future<void> remove(String operationId) async {
    _storage.remove(operationId);
  }

  @override
  Future<SyncOperation?> getById(String operationId) async {
    return _storage[operationId];
  }

  @override
  Future<List<SyncOperation>> getPendingForTenant(String tenantId) async {
    final list = _storage.values
        .where((op) =>
            op.tenantId == tenantId &&
            op.status != SyncOperationStatus.completed &&
            op.status != SyncOperationStatus.deadLetter)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  @override
  Future<List<SyncOperation>> getAllForTenant(String tenantId) async {
    final list = _storage.values.where((op) => op.tenantId == tenantId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  @override
  Future<void> clearForTenant(String tenantId) async {
    _storage.removeWhere((_, op) => op.tenantId == tenantId);
  }

  @override
  Future<void> clearAll() async {
    _storage.clear();
  }

  @override
  Future<void> dispose() async {}
}

/// Pure-Dart, disk-backed persistent queue storage writing to a JSON file.
///
/// Ensures queue persistence across application restarts and platform terminations.
class FileJsonQueueStorage implements SyncQueueStorage {
  final File file;
  final Map<String, SyncOperation> _cache = {};
  bool _initialized = false;
  Completer<void>? _pendingFlush;

  FileJsonQueueStorage({required this.file});

  @override
  Future<void> init() async {
    if (_initialized) return;

    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as List<dynamic>;
          for (final item in decoded) {
            final op = SyncOperation.fromJson(item as Map<String, dynamic>);
            // If the app crashed while an op was inFlight, reset it to pending
            if (op.status == SyncOperationStatus.inFlight) {
              _cache[op.id] = op.copyWith(status: SyncOperationStatus.pending);
            } else {
              _cache[op.id] = op;
            }
          }
        }
      } catch (e) {
        // Fall back to clean state if JSON file was corrupted
      }
    } else {
      await file.parent.create(recursive: true);
    }

    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
          'FileJsonQueueStorage is not initialized. Call init() first.');
    }
  }

  @override
  Future<void> save(SyncOperation operation) async {
    _ensureInitialized();
    _cache[operation.id] = operation;
    await _flush();
  }

  @override
  Future<void> saveBatch(List<SyncOperation> operations) async {
    _ensureInitialized();
    for (final op in operations) {
      _cache[op.id] = op;
    }
    await _flush();
  }

  @override
  Future<void> remove(String operationId) async {
    _ensureInitialized();
    if (_cache.containsKey(operationId)) {
      _cache.remove(operationId);
      await _flush();
    }
  }

  @override
  Future<SyncOperation?> getById(String operationId) async {
    _ensureInitialized();
    return _cache[operationId];
  }

  @override
  Future<List<SyncOperation>> getPendingForTenant(String tenantId) async {
    _ensureInitialized();
    final list = _cache.values
        .where((op) =>
            op.tenantId == tenantId &&
            op.status != SyncOperationStatus.completed &&
            op.status != SyncOperationStatus.deadLetter)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  @override
  Future<List<SyncOperation>> getAllForTenant(String tenantId) async {
    _ensureInitialized();
    final list = _cache.values.where((op) => op.tenantId == tenantId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  @override
  Future<void> clearForTenant(String tenantId) async {
    _ensureInitialized();
    _cache.removeWhere((_, op) => op.tenantId == tenantId);
    await _flush();
  }

  @override
  Future<void> clearAll() async {
    _ensureInitialized();
    _cache.clear();
    await _flush();
  }

  Future<void> _flush() async {
    if (_pendingFlush != null) {
      return _pendingFlush!.future;
    }

    final completer = Completer<void>();
    _pendingFlush = completer;

    try {
      final jsonList = _cache.values.map((op) => op.toJson()).toList();
      final content = jsonEncode(jsonList);

      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(content, flush: true);
      if (await tempFile.exists()) {
        await tempFile.rename(file.path);
      }
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _pendingFlush = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_pendingFlush != null) {
      await _pendingFlush!.future;
    }
  }
}

/// Callback for handling operations that exceed their maximum retry limit.
typedef DeadLetterCallback = void Function(SyncOperation operation);

/// Manages the persistence, retry backoff calculation, and queue lifecycle of sync operations.
class SyncQueueManager {
  final SyncQueueStorage storage;
  final BackoffCalculator backoffCalculator;
  final DeadLetterCallback? onDeadLetter;

  final StreamController<SyncOperation> _queueChangeController =
      StreamController<SyncOperation>.broadcast();

  SyncQueueManager({
    required this.storage,
    this.backoffCalculator = const BackoffCalculator(),
    this.onDeadLetter,
  });

  /// Reactive stream of queue changes (enqueued, retried, completed, failed).
  Stream<SyncOperation> get onQueueChanged => _queueChangeController.stream;

  /// Initializes the queue storage.
  Future<void> init() async {
    await storage.init();
  }

  /// Enqueues a new sync mutation after running security validation.
  Future<void> enqueue(SyncOperation operation) async {
    operation.validateSecurity();
    await storage.save(operation);
    _queueChangeController.add(operation);
  }

  /// Returns all operations for the specified [tenantId].
  Future<List<SyncOperation>> getOperationsForTenant(String tenantId) async {
    return await storage.getAllForTenant(tenantId);
  }

  /// Returns all pending operations for [tenantId] ready for execution.
  Future<List<SyncOperation>> getReadyOperations(String tenantId,
      [DateTime? now]) async {
    final pending = await storage.getPendingForTenant(tenantId);
    final current = now ?? DateTime.now().toUtc();
    return pending.where((op) => op.isReadyForAttempt(current)).toList();
  }

  /// Returns total count of pending operations for [tenantId].
  Future<int> getPendingCount(String tenantId) async {
    final pending = await storage.getPendingForTenant(tenantId);
    return pending.length;
  }

  /// Marks an operation as currently in-flight.
  Future<SyncOperation> markInFlight(SyncOperation operation) async {
    final updated = operation.copyWith(
      status: SyncOperationStatus.inFlight,
      lastAttemptAt: DateTime.now().toUtc(),
    );
    await storage.save(updated);
    _queueChangeController.add(updated);
    return updated;
  }

  /// Marks an operation as successfully completed and removes it from the queue.
  Future<void> markCompleted(String operationId) async {
    final op = await storage.getById(operationId);
    await storage.remove(operationId);
    if (op != null) {
      final completed = op.copyWith(status: SyncOperationStatus.completed);
      _queueChangeController.add(completed);
    }
  }

  /// Handles failure of an operation by applying exponential backoff and jitter.
  ///
  /// If the operation has exceeded its [SyncOperation.maxRetries], it transitions
  /// to [SyncOperationStatus.deadLetter] and triggers [onDeadLetter].
  Future<SyncOperation> markFailed(
    SyncOperation operation, {
    required String error,
    bool isPermanent = false,
    Random? random,
  }) async {
    final nextRetryCount = operation.retryCount + 1;
    final hasExceededRetries =
        isPermanent || nextRetryCount >= operation.maxRetries;

    if (hasExceededRetries) {
      final deadLetterOp = operation.copyWith(
        status: SyncOperationStatus.deadLetter,
        retryCount: nextRetryCount,
        lastAttemptAt: DateTime.now().toUtc(),
        error: error,
      );
      await storage.save(deadLetterOp);
      _queueChangeController.add(deadLetterOp);
      onDeadLetter?.call(deadLetterOp);
      return deadLetterOp;
    }

    final delay =
        backoffCalculator.calculateBackoff(nextRetryCount, random: random);
    final nextAttemptAt = DateTime.now().toUtc().add(delay);

    final failedOp = operation.copyWith(
      status: SyncOperationStatus.failed,
      retryCount: nextRetryCount,
      lastAttemptAt: DateTime.now().toUtc(),
      nextAttemptAt: nextAttemptAt,
      error: error,
    );

    await storage.save(failedOp);
    _queueChangeController.add(failedOp);
    return failedOp;
  }

  /// Clears all queue records for a specific [tenantId].
  Future<void> clearForTenant(String tenantId) async {
    await storage.clearForTenant(tenantId);
  }

  /// Clears the entire queue across all tenants.
  Future<void> clearAll() async {
    await storage.clearAll();
  }

  /// Disposes resources.
  Future<void> dispose() async {
    await _queueChangeController.close();
    await storage.dispose();
  }
}
