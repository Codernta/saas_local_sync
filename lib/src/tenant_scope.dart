import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Exception thrown when an operation requires an active tenant but none is set.
class NoActiveTenantException implements Exception {
  final String message;
  const NoActiveTenantException([this.message = 'No active tenant is currently set in TenantScope.']);

  @override
  String toString() => 'NoActiveTenantException: $message';
}

/// Exception thrown when an operation target does not match the active tenant.
class TenantMismatchException implements Exception {
  final String activeTenantId;
  final String targetTenantId;
  final String message;

  TenantMismatchException({
    required this.activeTenantId,
    required this.targetTenantId,
    String? message,
  }) : message = message ??
            'Tenant mismatch! Active tenant is "$activeTenantId" but target tenant is "$targetTenantId".';

  @override
  String toString() => 'TenantMismatchException: $message';
}

/// Exception thrown when a tenant identifier or storage key fails security validation checks.
class TenantSecurityException extends ArgumentError {
  final String securityMessage;

  TenantSecurityException(this.securityMessage, [String? invalidVal])
      : super.value(invalidVal, 'securityCheck', securityMessage);

  @override
  String toString() =>
      'TenantSecurityException: $securityMessage${invalidValue != null ? ' (Invalid value: "$invalidValue")' : ''}';
}

/// Helper utility for generating and parsing tenant-scoped keys.
///
/// Prevents cross-tenant collision, injection attacks, and data leakage in underlying storage.
abstract final class ScopedKey {
  static const String prefixDelimiter = '__ts__';

  /// Regular expression restricting tenant identifiers to safe characters.
  /// Disallows path traversal, null bytes, control characters, and delimiter strings.
  static final RegExp validTenantIdPattern = RegExp(r'^[a-zA-Z0-9_\-\.@]+$');

  /// Validates [tenantId] against injection, directory traversal, and delimiter collision attacks.
  static void validateTenantId(String tenantId) {
    if (tenantId.isEmpty) {
      throw TenantSecurityException('Tenant ID cannot be empty');
    }
    if (tenantId.contains(prefixDelimiter)) {
      throw TenantSecurityException(
        'Security violation: Tenant ID cannot contain prefix delimiter "$prefixDelimiter"',
        tenantId,
      );
    }
    if (tenantId.contains('..') ||
        tenantId.contains('/') ||
        tenantId.contains('\\') ||
        tenantId.contains('\x00')) {
      throw TenantSecurityException(
        'Security violation: Tenant ID cannot contain path traversal characters or null bytes',
        tenantId,
      );
    }
    if (!validTenantIdPattern.hasMatch(tenantId)) {
      throw TenantSecurityException(
        'Security violation: Tenant ID contains illegal characters. Only alphanumeric, -, _, ., @ are allowed',
        tenantId,
      );
    }
  }

  /// Validates [key] to prevent delimiter collision and traversal attacks.
  static void validateKey(String key) {
    if (key.isEmpty) {
      throw TenantSecurityException('Storage key cannot be empty');
    }
    if (key.contains(prefixDelimiter)) {
      throw TenantSecurityException(
        'Security violation: Storage key cannot contain delimiter "$prefixDelimiter"',
        key,
      );
    }
    if (key.contains('\x00')) {
      throw TenantSecurityException(
        'Security violation: Storage key cannot contain null bytes',
        key,
      );
    }
  }

  /// Formats a key with the given [tenantId] namespace.
  ///
  /// Enforces security validation on both [tenantId] and [key] before generating the scoped key.
  static String format(String tenantId, String key) {
    validateTenantId(tenantId);
    validateKey(key);
    return 't_$tenantId$prefixDelimiter$key';
  }

  /// Checks if [scopedKey] belongs to [tenantId].
  static bool belongsToTenant(String scopedKey, String tenantId) {
    final prefix = 't_$tenantId$prefixDelimiter';
    return scopedKey.startsWith(prefix);
  }

  /// Extracts the raw key by stripping the tenant namespace prefix.
  ///
  /// Returns `null` if [scopedKey] does not belong to [tenantId].
  static String? extractRawKey(String scopedKey, String tenantId) {
    final prefix = 't_$tenantId$prefixDelimiter';
    if (!scopedKey.startsWith(prefix)) {
      return null;
    }
    return scopedKey.substring(prefix.length);
  }

  /// Extracts the tenant ID from a formatted [scopedKey].
  ///
  /// Returns `null` if the key is not in a valid scoped format.
  static String? extractTenantId(String scopedKey) {
    if (!scopedKey.startsWith('t_')) return null;
    final delimIndex = scopedKey.indexOf(prefixDelimiter);
    if (delimIndex == -1 || delimIndex <= 2) return null;
    return scopedKey.substring(2, delimIndex);
  }
}

/// Utility class for auditing multi-tenant isolation and security policies at runtime.
abstract final class TenantSecurityChecker {
  /// Verifies that [tenantId] complies with all security policies.
  static bool isTenantIdSafe(String tenantId) {
    try {
      ScopedKey.validateTenantId(tenantId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Verifies that [key] complies with all security policies.
  static bool isKeySafe(String key) {
    try {
      ScopedKey.validateKey(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Runs an automated isolation audit on [store] verifying that operations
  /// performed under one tenant do not appear in or affect another tenant.
  static Future<bool> auditStoreIsolation<T>({
    required ScopedStoreWrapper<T> store,
    required String tenantA,
    required String tenantB,
    required T testValueA,
    required T testValueB,
  }) async {
    final scope = store.scope;
    final initialTenant = scope.activeTenantIdOrNull;

    try {
      // 1. Write in tenant A
      scope.setTenant(tenantA);
      await store.put('__security_audit_key__', testValueA);

      // 2. Switch to tenant B and verify absence
      scope.setTenant(tenantB);
      final readFromB = await store.get('__security_audit_key__');
      if (readFromB != null) return false;

      // 3. Write in tenant B
      await store.put('__security_audit_key__', testValueB);

      // 4. Switch back to tenant A and verify integrity
      scope.setTenant(tenantA);
      final readFromA = await store.get('__security_audit_key__');
      if (readFromA != testValueA) return false;

      // Clean up
      await store.delete('__security_audit_key__');
      scope.setTenant(tenantB);
      await store.delete('__security_audit_key__');

      return true;
    } finally {
      if (initialTenant != null) {
        scope.setTenant(initialTenant);
      } else {
        scope.clearTenant();
      }
    }
  }
}

/// Manages the currently active [activeTenantId] across the application.
///
/// Ensures logical isolation and notifies listeners whenever the active
/// tenant context changes (e.g., when a user switches workspaces or organizations).
class TenantScope {
  String? _activeTenantId;
  final StreamController<String?> _tenantChangeController =
      StreamController<String?>.broadcast();

  /// Creates a [TenantScope] with an optional initial tenant ID.
  TenantScope([String? initialTenantId]) {
    if (initialTenantId != null) {
      setTenant(initialTenantId);
    }
  }

  /// Returns the currently active tenant ID.
  ///
  /// Throws [NoActiveTenantException] if no tenant is currently set.
  String get activeTenantId {
    final tenant = _activeTenantId;
    if (tenant == null || tenant.isEmpty) {
      throw const NoActiveTenantException();
    }
    return tenant;
  }

  /// Returns the active tenant ID, or `null` if none is set.
  String? get activeTenantIdOrNull => _activeTenantId;

  /// Whether a tenant is currently active.
  bool get hasActiveTenant =>
      _activeTenantId != null && _activeTenantId!.isNotEmpty;

  /// Stream of tenant changes. Emits the new tenant ID or `null` on logout/switch.
  Stream<String?> get onTenantChanged => _tenantChangeController.stream;

  /// Sets the active tenant ID and notifies listeners if changed.
  ///
  /// Enforces security validation on [tenantId] against delimiter injection,
  /// path traversal, and illegal characters.
  void setTenant(String tenantId) {
    final trimmed = tenantId.trim();
    ScopedKey.validateTenantId(trimmed);
    if (_activeTenantId == trimmed) return;

    _activeTenantId = trimmed;
    _tenantChangeController.add(trimmed);
  }

  /// Clears the active tenant context.
  void clearTenant() {
    if (_activeTenantId == null) return;
    _activeTenantId = null;
    _tenantChangeController.add(null);
  }

  /// Verifies that the specified [tenantId] matches the currently active tenant.
  ///
  /// Throws [NoActiveTenantException] if no tenant is set, or
  /// [TenantMismatchException] if it does not match.
  void ensureActiveTenant(String tenantId) {
    final current = activeTenantId;
    if (current != tenantId) {
      throw TenantMismatchException(
        activeTenantId: current,
        targetTenantId: tenantId,
      );
    }
  }

  /// Scopes a raw storage [key] using the currently active tenant.
  String scopeKey(String key) {
    return ScopedKey.format(activeTenantId, key);
  }

  /// Closes internal stream controllers.
  Future<void> dispose() async {
    await _tenantChangeController.close();
  }
}

/// Generic interface for local persistence stores.
///
/// Can be implemented for SQLite, Drift, Hive, Isar, shared_preferences,
/// or pure-Dart file/memory stores.
abstract class LocalStoreAdapter<T> {
  /// Initializes the store (e.g. opens database, reads index).
  Future<void> init();

  /// Puts a value at [key].
  Future<void> put(String key, T value);

  /// Retrieves the value at [key], or `null` if not found.
  Future<T?> get(String key);

  /// Deletes the value at [key].
  Future<void> delete(String key);

  /// Retrieves all key-value entries in this store.
  Future<Map<String, T>> getAll();

  /// Clears all entries in this store.
  Future<void> clear();

  /// Watches all key-value entries in this store.
  Stream<Map<String, T>> watchAll();

  /// Releases resources used by the store.
  Future<void> dispose();
}

/// Scoped storage wrapper that decorates any [LocalStoreAdapter] with strict
/// tenant-scoped logical isolation based on [TenantScope].
///
/// Keys are transparently prefixed with the active tenant ID. When querying
/// or clearing data, only the active tenant's data is accessed or deleted,
/// ensuring zero data leakage between workspaces.
class ScopedStoreWrapper<T> {
  final LocalStoreAdapter<T> _adapter;
  final TenantScope _scope;
  final StreamController<Map<String, T>> _watchController =
      StreamController<Map<String, T>>.broadcast();
  StreamSubscription<Map<String, T>>? _adapterSub;
  StreamSubscription<String?>? _tenantSub;

  ScopedStoreWrapper({
    required LocalStoreAdapter<T> adapter,
    required TenantScope scope,
  })  : _adapter = adapter,
        _scope = scope {
    _adapterSub = _adapter.watchAll().listen((_) => _emitScopedUpdate());
    _tenantSub = _scope.onTenantChanged.listen((_) => _emitScopedUpdate());
  }

  /// The underlying local store adapter.
  LocalStoreAdapter<T> get adapter => _adapter;

  /// The active tenant scope.
  TenantScope get scope => _scope;

  Future<void> _emitScopedUpdate() async {
    if (_watchController.isClosed) return;
    try {
      if (!_scope.hasActiveTenant) {
        _watchController.add(const {});
      } else {
        final data = await getAll();
        if (!_watchController.isClosed) {
          _watchController.add(data);
        }
      }
    } catch (_) {
      // Ignore emit errors if scope is transitioning
    }
  }

  /// Saves [value] at [rawKey] under the active tenant.
  Future<void> put(String rawKey, T value) async {
    final tenantId = _scope.activeTenantId;
    final scopedKey = ScopedKey.format(tenantId, rawKey);
    await _adapter.put(scopedKey, value);
  }

  /// Retrieves the value at [rawKey] for the active tenant, or `null`.
  Future<T?> get(String rawKey) async {
    final tenantId = _scope.activeTenantId;
    final scopedKey = ScopedKey.format(tenantId, rawKey);
    return await _adapter.get(scopedKey);
  }

  /// Deletes the entry at [rawKey] for the active tenant.
  Future<void> delete(String rawKey) async {
    final tenantId = _scope.activeTenantId;
    final scopedKey = ScopedKey.format(tenantId, rawKey);
    await _adapter.delete(scopedKey);
  }

  /// Returns all entries belonging strictly to the active tenant.
  ///
  /// The returned map contains raw keys (without the internal tenant prefix).
  Future<Map<String, T>> getAll() async {
    final tenantId = _scope.activeTenantId;
    final allEntries = await _adapter.getAll();
    final result = <String, T>{};

    for (final entry in allEntries.entries) {
      final rawKey = ScopedKey.extractRawKey(entry.key, tenantId);
      if (rawKey != null) {
        result[rawKey] = entry.value;
      }
    }
    return result;
  }

  /// Clears only the active tenant's records, leaving all other tenants untouched.
  Future<void> clear() async {
    final tenantId = _scope.activeTenantId;
    final allEntries = await _adapter.getAll();

    for (final key in allEntries.keys) {
      if (ScopedKey.belongsToTenant(key, tenantId)) {
        await _adapter.delete(key);
      }
    }
  }

  /// Reactive stream of the active tenant's key-value entries.
  ///
  /// Automatically re-emits when items are added/removed or when the tenant is switched.
  Stream<Map<String, T>> watchAll() async* {
    if (_scope.hasActiveTenant) {
      yield await getAll();
    } else {
      yield const {};
    }
    yield* _watchController.stream;
  }

  /// Closes internal resources.
  Future<void> dispose() async {
    await _adapterSub?.cancel();
    await _tenantSub?.cancel();
    await _watchController.close();
  }
}

/// In-memory implementation of [LocalStoreAdapter] with reactive change notifications.
class InMemoryStoreAdapter<T> implements LocalStoreAdapter<T> {
  final Map<String, T> _storage = {};
  final StreamController<Map<String, T>> _streamController =
      StreamController<Map<String, T>>.broadcast();

  InMemoryStoreAdapter([Map<String, T>? initialData]) {
    if (initialData != null) {
      _storage.addAll(initialData);
    }
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> put(String key, T value) async {
    _storage[key] = value;
    _notify();
  }

  @override
  Future<T?> get(String key) async {
    return _storage[key];
  }

  @override
  Future<void> delete(String key) async {
    if (_storage.containsKey(key)) {
      _storage.remove(key);
      _notify();
    }
  }

  @override
  Future<Map<String, T>> getAll() async {
    return Map<String, T>.unmodifiable(_storage);
  }

  @override
  Future<void> clear() async {
    _storage.clear();
    _notify();
  }

  @override
  Stream<Map<String, T>> watchAll() async* {
    yield Map<String, T>.unmodifiable(_storage);
    yield* _streamController.stream;
  }

  void _notify() {
    if (!_streamController.isClosed) {
      _streamController.add(Map<String, T>.unmodifiable(_storage));
    }
  }

  @override
  Future<void> dispose() async {
    await _streamController.close();
  }
}

/// Pure-Dart, disk-backed persistent [LocalStoreAdapter] storing data as JSON.
///
/// Features in-memory caching for instant synchronous reads and asynchronous
/// atomic disk flushing (write to temp file then rename) to prevent corruption.
class FileJsonStoreAdapter<T> implements LocalStoreAdapter<T> {
  final File file;
  final T Function(Map<String, dynamic> json) fromJson;
  final Map<String, dynamic> Function(T value) toJson;

  final Map<String, T> _memoryCache = {};
  final StreamController<Map<String, T>> _streamController =
      StreamController<Map<String, T>>.broadcast();
  bool _initialized = false;
  Completer<void>? _pendingFlush;

  FileJsonStoreAdapter({
    required this.file,
    required this.fromJson,
    required this.toJson,
  });

  @override
  Future<void> init() async {
    if (_initialized) return;

    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          for (final entry in decoded.entries) {
            _memoryCache[entry.key] =
                fromJson(entry.value as Map<String, dynamic>);
          }
        }
      } catch (e) {
        // Corrupted file recovery: start with empty cache
      }
    } else {
      await file.parent.create(recursive: true);
    }

    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
          'FileJsonStoreAdapter is not initialized. Call init() first.');
    }
  }

  @override
  Future<void> put(String key, T value) async {
    _ensureInitialized();
    _memoryCache[key] = value;
    _notify();
    await _flushToDisk();
  }

  @override
  Future<T?> get(String key) async {
    _ensureInitialized();
    return _memoryCache[key];
  }

  @override
  Future<void> delete(String key) async {
    _ensureInitialized();
    if (_memoryCache.containsKey(key)) {
      _memoryCache.remove(key);
      _notify();
      await _flushToDisk();
    }
  }

  @override
  Future<Map<String, T>> getAll() async {
    _ensureInitialized();
    return Map<String, T>.unmodifiable(_memoryCache);
  }

  @override
  Future<void> clear() async {
    _ensureInitialized();
    _memoryCache.clear();
    _notify();
    await _flushToDisk();
  }

  @override
  Stream<Map<String, T>> watchAll() async* {
    _ensureInitialized();
    yield Map<String, T>.unmodifiable(_memoryCache);
    yield* _streamController.stream;
  }

  void _notify() {
    if (!_streamController.isClosed) {
      _streamController.add(Map<String, T>.unmodifiable(_memoryCache));
    }
  }

  Future<void> _flushToDisk() async {
    if (_pendingFlush != null) {
      return _pendingFlush!.future;
    }

    final completer = Completer<void>();
    _pendingFlush = completer;

    try {
      final jsonMap = <String, dynamic>{};
      for (final entry in _memoryCache.entries) {
        jsonMap[entry.key] = toJson(entry.value);
      }
      final jsonString = jsonEncode(jsonMap);

      // Atomic write: write to temp file then rename
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(jsonString, flush: true);
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
    await _streamController.close();
  }
}
