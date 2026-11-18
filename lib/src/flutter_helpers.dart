import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'sync_client.dart';
import 'sync_repository.dart';

/// Wraps a [SyncEngine] into Flutter's [ChangeNotifier] / [ValueListenable] ecosystem.
class SyncEngineNotifier extends ChangeNotifier
    implements ValueListenable<SyncEngineState> {
  final SyncEngine engine;
  late StreamSubscription<SyncEngineState> _subscription;

  SyncEngineNotifier(this.engine) {
    _subscription = engine.stateStream.listen((_) {
      notifyListeners();
    });
  }

  @override
  SyncEngineState get value => engine.currentState;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// A ready-to-use Flutter widget that renders an animated, color-coded badge
/// reflecting the engine's current [SyncStatus].
class SyncStatusBadge extends StatelessWidget {
  final SyncStatus status;
  final int pendingCount;
  final bool compact;

  const SyncStatusBadge({
    super.key,
    required this.status,
    this.pendingCount = 0,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    Color backgroundColor;
    Color textColor;
    IconData icon;
    String label;

    switch (status) {
      case SyncStatus.synced:
        backgroundColor = Colors.green.shade50;
        textColor = Colors.green.shade800;
        icon = Icons.check_circle_outline;
        label = 'Synced';
        break;
      case SyncStatus.syncing:
        backgroundColor = Colors.blue.shade50;
        textColor = Colors.blue.shade800;
        icon = Icons.sync;
        label = pendingCount > 0 ? 'Syncing ($pendingCount)' : 'Syncing...';
        break;
      case SyncStatus.offline:
        backgroundColor = Colors.orange.shade50;
        textColor = Colors.orange.shade900;
        icon = Icons.cloud_off_outlined;
        label = pendingCount > 0 ? 'Offline ($pendingCount pending)' : 'Offline';
        break;
      case SyncStatus.error:
        backgroundColor = Colors.red.shade50;
        textColor = Colors.red.shade800;
        icon = Icons.error_outline;
        label = 'Sync Error';
        break;
    }

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: textColor.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == SyncStatus.syncing)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(textColor),
                ),
              )
            else
              Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: textColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == SyncStatus.syncing)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(textColor),
              ),
            )
          else
            Icon(icon, size: 16, color: textColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// A badge displaying an individual entity's [SyncState].
class EntitySyncChip extends StatelessWidget {
  final SyncState syncState;

  const EntitySyncChip({
    super.key,
    required this.syncState,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    IconData icon;
    String text;

    switch (syncState) {
      case SyncState.synced:
        bg = Colors.green.shade50;
        fg = Colors.green.shade700;
        icon = Icons.cloud_done;
        text = 'Synced';
        break;
      case SyncState.pendingCreation:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade900;
        icon = Icons.cloud_upload_outlined;
        text = 'Offline (New)';
        break;
      case SyncState.pendingUpdate:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade900;
        icon = Icons.pending_outlined;
        text = 'Offline (Edited)';
        break;
      case SyncState.pendingDeletion:
        bg = Colors.red.shade50;
        fg = Colors.red.shade700;
        icon = Icons.delete_outline;
        text = 'Deleting';
        break;
      case SyncState.conflictResolved:
        bg = Colors.indigo.shade50;
        fg = Colors.indigo.shade700;
        icon = Icons.call_merge;
        text = 'Resolved';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
