## 1.0.2

* Updated package description to meet Pana's length requirements (between 60 and 180 characters).
* Standardized OSI-approved BSD-3-Clause license file format.
* Decoupled `flutter_helpers.dart` to rely exclusively on `package:flutter/widgets.dart` to prevent future deprecation warnings on Flutter 3.47+.
* Enhanced documentation comments for `BackoffCalculator` and public APIs.
* Enforced full code formatting across all libraries and tests via `dart format`.

## 1.0.1

* Added official package banner/poster artwork to documentation.
* **Security Checks & Hardening**:
  - Added `TenantSecurityException` and strict validation of tenant identifiers and storage keys.
  - Implemented delimiter collision and path traversal protection in `ScopedKey.validateTenantId` and `ScopedKey.validateKey`.
  - Added `SyncOperation.validateSecurity()` to block malicious URI schemes (e.g. `javascript:`, `file:`, `data:`) and protect against oversized payload DoS attacks.
  - Added runtime tenant isolation auditor `TenantSecurityChecker.auditStoreIsolation`.
  - Added dedicated security unit test suite `test/security_checks_test.dart`.

## 1.0.0

* Initial release of `saas_local_sync`.
* Strict tenant-scoped logical isolation with `TenantScope` and `ScopedStoreWrapper`.
* Optimistic UI updates with instant local persistence and background mutation queuing.
* Exponential backoff calculator with customizable base delay, max delay, and randomized jitter.
* Disk-backed persistent retry queue (`FileJsonQueueStorage`) with process crash recovery.
* Pluggable conflict resolution strategies: `lastWriteWins`, `serverAuthoritative`, `clientAuthoritative`, and `customMerge`.
* Generic typed repository abstraction (`SyncRepository<T, ID>`) and storage adapter interface (`LocalStoreAdapter<T>`).
* Network connectivity monitoring (`FlutterConnectivityMonitor` and `PluggableConnectivityMonitor`).
* Flutter UI widgets and helpers (`SyncEngineNotifier`, `SyncStatusBadge`, `EntitySyncChip`).
* Interactive example app and full unit test suite.
