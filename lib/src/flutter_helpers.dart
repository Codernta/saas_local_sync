import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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
    String symbol;
    String label;

    switch (status) {
      case SyncStatus.synced:
        backgroundColor = const Color(0xFFE8F5E9);
        textColor = const Color(0xFF2E7D32);
        symbol = '✓';
        label = 'Synced';
        break;
      case SyncStatus.syncing:
        backgroundColor = const Color(0xFFE3F2FD);
        textColor = const Color(0xFF1565C0);
        symbol = '⟳';
        label = pendingCount > 0 ? 'Syncing ($pendingCount)' : 'Syncing...';
        break;
      case SyncStatus.offline:
        backgroundColor = const Color(0xFFFFF3E0);
        textColor = const Color(0xFFE65100);
        symbol = '☁';
        label =
            pendingCount > 0 ? 'Offline ($pendingCount pending)' : 'Offline';
        break;
      case SyncStatus.error:
        backgroundColor = const Color(0xFFFFEBEE);
        textColor = const Color(0xFFC62828);
        symbol = '!';
        label = 'Sync Error';
        break;
    }

    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 12, vertical: 6);
    final borderRadius = BorderRadius.circular(compact ? 12 : 16);
    final fontSize = compact ? 11.0 : 12.0;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: borderRadius,
        border: Border.all(color: textColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == SyncStatus.syncing)
            _SpinningIndicator(
              color: textColor,
              size: compact ? 12.0 : 14.0,
            )
          else
            Text(
              symbol,
              style: TextStyle(
                fontSize: compact ? 12 : 14,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
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
    String symbol;
    String text;

    switch (syncState) {
      case SyncState.synced:
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF2E7D32);
        symbol = '✓';
        text = 'Synced';
        break;
      case SyncState.pendingCreation:
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFFF8F00);
        symbol = '↑';
        text = 'Offline (New)';
        break;
      case SyncState.pendingUpdate:
        bg = const Color(0xFFFFF8E1);
        fg = const Color(0xFFFF8F00);
        symbol = '✎';
        text = 'Offline (Edited)';
        break;
      case SyncState.pendingDeletion:
        bg = const Color(0xFFFFEBEE);
        fg = const Color(0xFFC62828);
        symbol = '✕';
        text = 'Deleting';
        break;
      case SyncState.conflictResolved:
        bg = const Color(0xFFE8EAF6);
        fg = const Color(0xFF283593);
        symbol = '⑂';
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
          Text(
            symbol,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: fg,
            ),
          ),
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

class _SpinningIndicator extends StatefulWidget {
  final Color color;
  final double size;

  const _SpinningIndicator({required this.color, required this.size});

  @override
  State<_SpinningIndicator> createState() => _SpinningIndicatorState();
}

class _SpinningIndicatorState extends State<_SpinningIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.rotate(
          angle: _controller.value * 2 * math.pi,
          child: CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _ArcPainter(widget.color),
          ),
        );
      },
    );
  }
}

class _ArcPainter extends CustomPainter {
  final Color color;
  _ArcPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawArc(rect, 0, 4.5, false, paint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) =>
      oldDelegate.color != color;
}
