import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

/// Configuration for connecting to the AIVR mesh / relay.
class AivrCoreConfig {
  final String meshHost;
  final int meshPort;
  final String relayHost;
  final int relayPort;
  final Duration heartbeatInterval;

  const AivrCoreConfig({
    this.meshHost = '127.0.0.1',
    this.meshPort = 12000,
    this.relayHost = '127.0.0.1',
    this.relayPort = 9800,
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  String get meshEndpoint => '$meshHost:$meshPort';
  String get relayEndpoint => '$relayHost:$relayPort';
}

/// Token usage for a single inference request.
class TokenUsage {
  final int tokensIn;
  final int tokensOut;
  final String modelId;
  final double inferenceTimeMs;

  const TokenUsage({
    required this.tokensIn,
    required this.tokensOut,
    required this.modelId,
    this.inferenceTimeMs = 0,
  });

  int get totalTokens => tokensIn + tokensOut;

  Map<String, dynamic> toJson() => {
        'tokens_in': tokensIn,
        'tokens_out': tokensOut,
        'model_id': modelId,
        'inference_time_ms': inferenceTimeMs,
      };
}

/// Aggregate stats tracked by the bridge.
class AivrNodeStats {
  int totalTokensIn = 0;
  int totalTokensOut = 0;
  int requestCount = 0;
  int pendingRequests = 0;
  double lastTokenSpeed = 0.0; // tok/s for last request
  DateTime bootTime = DateTime.now();

  int get tokensEarned => ((totalTokensIn + totalTokensOut) * 0.95).toInt();
  int get uptimeSeconds => DateTime.now().difference(bootTime).inSeconds;

  void recordUsage(TokenUsage usage) {
    totalTokensIn += usage.tokensIn;
    totalTokensOut += usage.tokensOut;
    requestCount++;
    if (usage.inferenceTimeMs > 0) {
      lastTokenSpeed = (usage.tokensOut / (usage.inferenceTimeMs / 1000));
    }
  }

  Map<String, dynamic> toJson() => {
        'uptime_seconds': uptimeSeconds,
        'request_count': requestCount,
        'tokens_in': totalTokensIn,
        'tokens_out': totalTokensOut,
        'earned': tokensEarned,
        'token_speed': double.parse(lastTokenSpeed.toStringAsFixed(1)),
        'pending_requests': pendingRequests,
      };
}

/// AIVR Core Bridge — manages mesh registration, heartbeat, and token reporting.
///
/// Lifecycle:
///   1. `initialize()` — set up config, generate node ID.
///   2. `registerNode()` — announce this node + its models to the mesh.
///   3. `reportTokens()` — call after each inference to credit the node.
///   4. `updateModels()` — call when the model list changes.
///   5. `deregisterNode()` — call on server stop / app background.
class AivrCoreBridge {
  final AivrCoreConfig config;
  final String nodeId;
  final AivrNodeStats stats = AivrNodeStats();
  final List<String> _logs = [];

  bool _registered = false;
  Timer? _heartbeatTimer;
  String? _localIp;
  int? _serverPort;

  // Callbacks for the UI
  void Function(String log)? onLog;

  AivrCoreBridge({
    AivrCoreConfig? config,
    String? nodeId,
  })  : config = config ?? const AivrCoreConfig(),
        nodeId = nodeId ?? const Uuid().v4();

  bool get isRegistered => _registered;
  List<String> get logs => List.unmodifiable(_logs);

  void _log(String message) {
    final entry = '[AIVR] $message';
    _logs.add(entry);
    onLog?.call(entry);
    debugPrint(entry);
  }

  /// Initialize the bridge. Call once at app start.
  Future<void> initialize({String? localIp, int? serverPort}) async {
    _localIp = localIp;
    _serverPort = serverPort;
    stats.bootTime = DateTime.now();
    _log('Bridge initialized — node=$nodeId mesh=${config.meshEndpoint}');
  }

  /// Register this node on the AIVR mesh with its available models.
  Future<bool> registerNode({
    required List<ModelInfo> models,
    required String localIp,
    required int serverPort,
  }) async {
    _localIp = localIp;
    _serverPort = serverPort;

    final modelsPayload = models
        .where((m) => m.isDownloaded)
        .map((m) => {
              'id': m.id,
              'name': m.name,
              'size': m.size,
              'context_window': m.contextWindow,
              'token_limit': m.tokenLimit,
              'target_unit': m.targetUnit,
              'quantization': m.quantization,
            })
        .toList();

    final registration = {
      'type': 'node_register',
      'node_id': nodeId,
      'ip': localIp,
      'port': serverPort,
      'capabilities': {
        'openai_compat': true,
        'streaming': true,
        'chat_completions': true,
      },
      'models': modelsPayload,
      'timestamp': DateTime.now().toIso8601String(),
    };

    try {
      // Attempt mesh registration via UDP (Port 12000)
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final data = utf8.encode(jsonEncode(registration));
      socket.send(
        data,
        InternetAddress(config.meshHost),
        config.meshPort,
      );
      socket.close();

      _registered = true;
      _log('Registered on mesh with ${modelsPayload.length} model(s)');

      // Start heartbeat
      _startHeartbeat();
      return true;
    } catch (e) {
      _log('Mesh registration failed (offline mode): $e');
      // Still mark as "registered" locally — the node works standalone
      _registered = true;
      _startHeartbeat();
      return false;
    }
  }

  /// Deregister from the mesh (server stop / background).
  Future<void> deregisterNode() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (!_registered) return;

    try {
      final payload = {
        'type': 'node_deregister',
        'node_id': nodeId,
        'timestamp': DateTime.now().toIso8601String(),
      };

      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(
        utf8.encode(jsonEncode(payload)),
        InternetAddress(config.meshHost),
        config.meshPort,
      );
      socket.close();
    } catch (_) {
      // Best-effort deregistration
    }

    _registered = false;
    _log('Node deregistered from mesh');
  }

  /// Report token usage after each inference request.
  /// This credits the node in the AIVR orchestrator for earned tokens.
  void reportTokens(TokenUsage usage) {
    stats.recordUsage(usage);

    // Relay to AIVR Core via UDP (fire-and-forget)
    _sendToRelay({
      'type': 'token_report',
      'node_id': nodeId,
      'usage': usage.toJson(),
      'cumulative': {
        'tokens_in': stats.totalTokensIn,
        'tokens_out': stats.totalTokensOut,
        'earned': stats.tokensEarned,
        'requests': stats.requestCount,
      },
      'timestamp': DateTime.now().toIso8601String(),
    });

    _log(
      'Tokens reported: in=${usage.tokensIn} out=${usage.tokensOut} '
      'speed=${stats.lastTokenSpeed.toStringAsFixed(1)} tok/s '
      'earned_total=${stats.tokensEarned}',
    );
  }

  /// Update the model list advertised to the mesh.
  Future<void> updateModels(List<ModelInfo> models) async {
    final modelsPayload = models
        .where((m) => m.isDownloaded)
        .map((m) => {
              'id': m.id,
              'name': m.name,
              'size': m.size,
              'quantization': m.quantization,
              'target_unit': m.targetUnit,
            })
        .toList();

    _sendToRelay({
      'type': 'model_update',
      'node_id': nodeId,
      'models': modelsPayload,
      'timestamp': DateTime.now().toIso8601String(),
    });

    _log('Model list updated: ${modelsPayload.length} model(s) advertised');
  }

  /// Build the full stats JSON for the /v1/internal/stats endpoint.
  Map<String, dynamic> getStatsJson({String? activeModelId}) {
    final s = stats.toJson();
    s['model_id'] = activeModelId ?? 'none';
    s['node_id'] = nodeId;
    s['registered'] = _registered;
    s['mesh'] = config.meshEndpoint;
    return s;
  }

  /// Build the full health JSON for the / endpoint per spec.
  Map<String, dynamic> getHealthJson({
    String? activeModelId,
    String? activeModelName,
    String version = '1.0.0',
  }) {
    return {
      'status': _registered ? 'running' : 'idle',
      'model': activeModelName ?? 'none',
      'model_id': activeModelId ?? 'none',
      'version': version,
      'uptime': stats.uptimeSeconds,
      'requests': stats.requestCount,
      'active_requests': stats.pendingRequests,
      'tokens_per_second': double.parse(stats.lastTokenSpeed.toStringAsFixed(1)),
      'node_id': nodeId,
      'mesh': config.meshEndpoint,
      'aivr_registered': _registered,
    };
  }

  // --- Internal helpers ---------------------------------------------------

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(config.heartbeatInterval, (_) {
      _sendHeartbeat();
    });
  }

  void _sendHeartbeat() {
    _sendToRelay({
      'type': 'heartbeat',
      'node_id': nodeId,
      'ip': _localIp,
      'port': _serverPort,
      'uptime': stats.uptimeSeconds,
      'tokens_in': stats.totalTokensIn,
      'tokens_out': stats.totalTokensOut,
      'requests': stats.requestCount,
      'pending': stats.pendingRequests,
      'token_speed': stats.lastTokenSpeed,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _sendToRelay(Map<String, dynamic> payload) async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(
        utf8.encode(jsonEncode(payload)),
        InternetAddress(config.relayHost),
        config.relayPort,
      );
      socket.close();
    } catch (_) {
      // Fire-and-forget — mesh may not be running
    }
  }

  /// Clean up resources.
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }
}
