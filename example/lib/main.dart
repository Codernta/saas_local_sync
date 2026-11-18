import 'package:flutter/material.dart';
import 'package:saas_local_sync/saas_local_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SaasSyncExampleApp());
}

/// Domain entity representing a task within a tenant workspace.
class TaskItem implements SyncEntity {
  @override
  final String id;
  @override
  final String tenantId;
  final String title;
  final String description;
  final bool isCompleted;
  @override
  final DateTime updatedAt;
  @override
  final bool isDeleted;
  @override
  final SyncState syncState;

  const TaskItem({
    required this.id,
    required this.tenantId,
    required this.title,
    this.description = '',
    this.isCompleted = false,
    required this.updatedAt,
    this.isDeleted = false,
    this.syncState = SyncState.synced,
  });

  TaskItem copyWith({
    String? id,
    String? tenantId,
    String? title,
    String? description,
    bool? isCompleted,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return TaskItem(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      title: title ?? this.title,
      description: description ?? this.description,
      isCompleted: isCompleted ?? this.isCompleted,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'tenantId': tenantId,
        'title': title,
        'description': description,
        'isCompleted': isCompleted,
        'updatedAt': updatedAt.toIso8601String(),
        'isDeleted': isDeleted,
        'syncState': syncState.toJson(),
      };

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
        id: json['id'] as String,
        tenantId: json['tenantId'] as String,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        isCompleted: json['isCompleted'] as bool? ?? false,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        isDeleted: json['isDeleted'] as bool? ?? false,
        syncState: SyncState.fromJson(json['syncState'] as String? ?? 'synced'),
      );
}

class SaasSyncExampleApp extends StatelessWidget {
  const SaasSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SaaS Local Sync Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
      ),
      home: const SyncDashboardScreen(),
    );
  }
}

class SyncDashboardScreen extends StatefulWidget {
  const SyncDashboardScreen({super.key});

  @override
  State<SyncDashboardScreen> createState() => _SyncDashboardScreenState();
}

class _SyncDashboardScreenState extends State<SyncDashboardScreen> {
  // Core Sync Engine Services
  late final TenantScope _tenantScope;
  late final InMemoryStoreAdapter<TaskItem> _localStore;
  late final ScopedStoreWrapper<TaskItem> _scopedStore;
  late final InMemoryQueueStorage _queueStorage;
  late final SyncQueueManager _queueManager;
  late final PluggableConnectivityMonitor _connectivityMonitor;
  late final MockRemoteTransport _remoteTransport;
  late final SyncEngine _syncEngine;
  late final SyncRepository<TaskItem, String> _taskRepository;

  bool _isInitialized = false;
  ConflictStrategy _selectedConflictStrategy = ConflictStrategy.customMerge;

  final Map<String, String> _tenants = {
    'tenant_1': 'Acme Corp (tenant_1)',
    'tenant_2': 'Globex Inc (tenant_2)',
  };

  @override
  void initState() {
    super.initState();
    _bootstrapEngine();
  }

  Future<void> _bootstrapEngine() async {
    // 1. Initialize Tenant Scope
    _tenantScope = TenantScope('tenant_1');

    // 2. Local Storage Layer
    _localStore = InMemoryStoreAdapter<TaskItem>();
    await _localStore.init();

    _scopedStore = ScopedStoreWrapper<TaskItem>(
      adapter: _localStore,
      scope: _tenantScope,
    );

    // 3. Persistent Queue
    _queueStorage = InMemoryQueueStorage();
    _queueManager = SyncQueueManager(
      storage: _queueStorage,
      backoffCalculator: const BackoffCalculator(
        baseDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 10),
      ),
    );

    // 4. Pluggable Connectivity & Remote Mock Transport
    _connectivityMonitor = PluggableConnectivityMonitor(initialOnline: true);
    _remoteTransport = MockRemoteTransport(
      simulatedLatency: const Duration(milliseconds: 400),
    );

    // 5. Orchestrator SyncEngine
    _syncEngine = SyncEngine(
      tenantScope: _tenantScope,
      queueManager: _queueManager,
      connectivity: _connectivityMonitor,
      transport: _remoteTransport,
      options: const SyncEngineOptions(
        autoSyncOnOnline: true,
        periodicSyncInterval: Duration(seconds: 15),
      ),
    );

    // 6. Build Conflict Resolver with selected strategy
    _setupRepository();

    await _syncEngine.initialize();

    // Seed some initial data for Tenant 1
    await _taskRepository.save(TaskItem(
      id: 'task_acme_1',
      tenantId: 'tenant_1',
      title: 'Review Q3 Financial Audit',
      description: 'Prepare report for board meeting',
      isCompleted: false,
      updatedAt: DateTime.now().toUtc(),
    ));

    // Seed some initial data for Tenant 2
    _tenantScope.setTenant('tenant_2');
    await _taskRepository.save(TaskItem(
      id: 'task_globex_1',
      tenantId: 'tenant_2',
      title: 'Renew ISO 27001 Certification',
      description: 'Auditor arrives next Tuesday',
      isCompleted: true,
      updatedAt: DateTime.now().toUtc(),
    ));

    // Switch back to Tenant 1 initially
    _tenantScope.setTenant('tenant_1');

    // Flush initial seed to mock backend so both are synced
    await _syncEngine.sync();

    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
  }

  void _setupRepository() {
    ConflictResolver<TaskItem> resolver;

    switch (_selectedConflictStrategy) {
      case ConflictStrategy.lastWriteWins:
        resolver = ConflictResolver<TaskItem>.lastWriteWins();
        break;
      case ConflictStrategy.serverAuthoritative:
        resolver = ConflictResolver<TaskItem>.serverAuthoritative();
        break;
      case ConflictStrategy.clientAuthoritative:
        resolver = ConflictResolver<TaskItem>.clientAuthoritative();
        break;
      case ConflictStrategy.customMerge:
        resolver = ConflictResolver<TaskItem>.custom((context) {
          final local = context.localEntity;
          final remote = context.remoteEntity;

          // Merge: combine notes from both local and remote parties
          final mergedTitle = local.title == remote.title
              ? local.title
              : '${local.title} [Merged: ${remote.title}]';
          final mergedDesc =
              '${local.description}\n[Cloud Sync]: ${remote.description}'
                  .trim();

          final mergedTask = local.copyWith(
            title: mergedTitle,
            description: mergedDesc,
            isCompleted: local.isCompleted || remote.isCompleted,
            updatedAt: DateTime.now().toUtc(),
          );

          return ConflictResolution<TaskItem>(
            resolvedEntity: mergedTask,
            strategyUsed: ConflictStrategy.customMerge,
            needsRemotePush: true,
            details: 'Merged conflicting task descriptions automatically.',
          );
        });
        break;
    }

    _taskRepository = SyncRepository<TaskItem, String>(
      entityType: 'task',
      endpoint: '/api/v1/tasks',
      store: _scopedStore,
      queueManager: _queueManager,
      conflictResolver: resolver,
      fromJson: TaskItem.fromJson,
      toJson: (t) => t.toJson(),
      withSyncState: (entity, state, time) => entity.copyWith(
        syncState: state,
        updatedAt: time,
      ),
    );

    _syncEngine.registerRepository(_taskRepository);
  }

  @override
  void dispose() {
    _syncEngine.dispose();
    _scopedStore.dispose();
    _localStore.dispose();
    super.dispose();
  }

  void _showConflictTriggerDialog(TaskItem task) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber),
            SizedBox(width: 8),
            Text('Simulate Cloud Conflict'),
          ],
        ),
        content: Text(
          'This will simulate an external team member editing "${task.title}" on the web while you are offline.\n\n'
          '1. A divergent state is injected on the mock server.\n'
          '2. The server arms a 409 Conflict on next push.\n'
          '3. Make an edit locally, then sync to watch the resolver reconcile the state!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _remoteTransport.injectServerChange(
                task.tenantId,
                task.id,
                {
                  'id': task.id,
                  'tenantId': task.tenantId,
                  'title': '${task.title} (Cloud Web Edit)',
                  'description': 'Urgent note added by colleague via Web App.',
                  'isCompleted': true,
                  'updatedAt': DateTime.now()
                      .toUtc()
                      .add(const Duration(minutes: 5))
                      .toIso8601String(),
                  'isDeleted': false,
                  'syncState': 'synced',
                },
              );
              _remoteTransport.triggerConflictOnNextPush(task.id);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      '⚡ Remote conflict armed! Edit this task or sync to trigger resolution.'),
                  backgroundColor: Colors.blueGrey,
                ),
              );
            },
            child: const Text('Arm Conflict'),
          ),
        ],
      ),
    );
  }

  void _showCreateTaskDialog() {
    final titleController = TextEditingController();
    final descController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add Task for ${_tenantScope.activeTenantId}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Task Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Save Task (Optimistic Offline Write)'),
              onPressed: () async {
                final title = titleController.text.trim();
                if (title.isEmpty) return;

                final newTask = TaskItem(
                  id: 'task_${DateTime.now().millisecondsSinceEpoch}',
                  tenantId: _tenantScope.activeTenantId,
                  title: title,
                  description: descController.text.trim(),
                  updatedAt: DateTime.now().toUtc(),
                );

                await _taskRepository.save(newTask);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return StreamBuilder<SyncEngineState>(
      stream: _syncEngine.stateStream,
      initialData: _syncEngine.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? _syncEngine.currentState;

        return Scaffold(
          appBar: AppBar(
            title: const Text('saas_local_sync Engine'),
            elevation: 1,
            actions: [
              // Online / Offline Simulation Toggle
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  children: [
                    Icon(
                      state.isOnline ? Icons.wifi : Icons.wifi_off,
                      color: state.isOnline ? Colors.green : Colors.red,
                      size: 20,
                    ),
                    const SizedBox(width: 4),
                    Switch(
                      value: state.isOnline,
                      onChanged: (online) {
                        _connectivityMonitor.setOnline(online);
                      },
                    ),
                  ],
                ),
              ),
              // Manual Sync Button
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Manual Sync Now',
                onPressed: state.isOnline ? () => _syncEngine.sync() : null,
              ),
            ],
          ),
          body: Column(
            children: [
              // 1. Tenant Workspace Switcher Banner
              _buildTenantHeader(state),

              // 2. Sync Engine Status Strip
              _buildStatusStrip(state),

              // 3. Task List View (Scoped strictly to active tenant)
              Expanded(
                child: StreamBuilder<List<TaskItem>>(
                  stream: _taskRepository.watchAll(),
                  builder: (context, taskSnapshot) {
                    final tasks = taskSnapshot.data ?? [];

                    if (tasks.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.inbox_outlined,
                                size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 12),
                            Text(
                              'No tasks in ${_tenants[_tenantScope.activeTenantId] ?? _tenantScope.activeTenantId}',
                              style: TextStyle(
                                  color: Colors.grey.shade600, fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                                'Zero data leakage verified across tenants!'),
                          ],
                        ),
                      );
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: tasks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final task = tasks[index];
                        return _buildTaskCard(task);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.add),
            label: const Text('New Task'),
            onPressed: _showCreateTaskDialog,
          ),
        );
      },
    );
  }

  Widget _buildTenantHeader(SyncEngineState state) {
    return Container(
      color: Colors.blue.shade50.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.business_center, color: Color(0xFF1D4ED8)),
          const SizedBox(width: 8),
          const Text(
            'Active Workspace:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _tenantScope.activeTenantId,
            underline: const SizedBox(),
            items: _tenants.entries.map((e) {
              return DropdownMenuItem(
                value: e.key,
                child: Text(e.value,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              );
            }).toList(),
            onChanged: (newTenant) {
              if (newTenant != null) {
                _syncEngine.switchTenant(newTenant);
                setState(() {});
              }
            },
          ),
          const Spacer(),
          // Conflict Strategy Selector
          PopupMenuButton<ConflictStrategy>(
            tooltip: 'Change Conflict Resolution Strategy',
            icon: const Icon(Icons.rule_folder_outlined),
            initialValue: _selectedConflictStrategy,
            onSelected: (strategy) {
              setState(() {
                _selectedConflictStrategy = strategy;
                _setupRepository();
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Strategy set to: ${strategy.name}')),
              );
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: ConflictStrategy.customMerge,
                child: Text('Custom Merge (Recommended)'),
              ),
              const PopupMenuItem(
                value: ConflictStrategy.lastWriteWins,
                child: Text('Last Write Wins'),
              ),
              const PopupMenuItem(
                value: ConflictStrategy.serverAuthoritative,
                child: Text('Server Authoritative'),
              ),
              const PopupMenuItem(
                value: ConflictStrategy.clientAuthoritative,
                child: Text('Client Authoritative'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusStrip(SyncEngineState state) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        children: [
          SyncStatusBadge(
            status: state.status,
            pendingCount: state.pendingOperationsCount,
          ),
          const SizedBox(width: 12),
          if (state.pendingOperationsCount > 0)
            Text(
              '${state.pendingOperationsCount} operations queued locally',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
            )
          else
            Text(
              state.isOnline
                  ? 'All changes synced with cloud'
                  : 'Operating fully offline',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
        ],
      ),
    );
  }

  Widget _buildTaskCard(TaskItem task) {
    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: task.isCompleted,
                  onChanged: (val) async {
                    final updated = task.copyWith(
                      isCompleted: val ?? false,
                      updatedAt: DateTime.now().toUtc(),
                    );
                    await _taskRepository.save(updated);
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          decoration: task.isCompleted
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (task.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          task.description,
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade700),
                        ),
                      ],
                    ],
                  ),
                ),
                EntitySyncChip(syncState: task.syncState),
              ],
            ),
            const Divider(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon:
                      const Icon(Icons.flash_on, size: 16, color: Colors.amber),
                  label: const Text('Test Conflict',
                      style: TextStyle(fontSize: 12)),
                  onPressed: () => _showConflictTriggerDialog(task),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: Colors.red),
                  onPressed: () async {
                    await _taskRepository.delete(task.id);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
