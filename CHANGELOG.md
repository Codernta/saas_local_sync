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
