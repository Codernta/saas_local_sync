import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Pluggable interface for monitoring network connectivity.
abstract class ConnectivityMonitor {
  /// Stream emitting boolean connection status (`true` = online, `false` = offline).
  Stream<bool> get onConnectivityChanged;

  /// Retrieves the current online/offline status asynchronously.
  Future<bool> get isOnline;

  /// Disposes resources and subscriptions.
  Future<void> dispose();
}

/// A manual, programmatic [ConnectivityMonitor] ideal for unit testing,
/// developer offline simulation toggles, and custom health-check polling.
class PluggableConnectivityMonitor implements ConnectivityMonitor {
  bool _isOnline;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();

  PluggableConnectivityMonitor({bool initialOnline = true})
      : _isOnline = initialOnline;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  @override
  Future<bool> get isOnline async => _isOnline;

  /// Manually toggles or sets the connection status.
  void setOnline(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    _controller.add(online);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Production [ConnectivityMonitor] implementation leveraging the `connectivity_plus` plugin.
class FlutterConnectivityMonitor implements ConnectivityMonitor {
  final Connectivity _connectivity;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _lastStatus = true;

  FlutterConnectivityMonitor({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity() {
    _subscription = _connectivity.onConnectivityChanged.listen(_handleResults);
  }

  void _handleResults(List<ConnectivityResult> results) {
    final online = _isAnyConnected(results);
    if (online != _lastStatus) {
      _lastStatus = online;
      _controller.add(online);
    }
  }

  bool _isAnyConnected(List<ConnectivityResult> results) {
    return results.any((r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
  }

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  @override
  Future<bool> get isOnline async {
    try {
      final results = await _connectivity.checkConnectivity();
      _lastStatus = _isAnyConnected(results);
      return _lastStatus;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
