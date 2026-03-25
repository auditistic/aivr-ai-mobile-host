import 'package:flutter/foundation.dart';
import 'device_capabilities.dart';

/// Connection state to the AI Farm.
enum FarmConnectionState { disconnected, connecting, connected, reconnecting }

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

/// Single source of truth for the entire node.
class NodeState extends ChangeNotifier {
  // Connection
  FarmConnectionState _connectionState = FarmConnectionState.disconnected;
  String? farmGatewayUrl;
  String nodeId = '';

  // Model
  String? currentModelId;
  String? currentModelName;
  bool isModelLoaded = false;

  // Download
  String? downloadingModelId;
  double? downloadProgress; // null = not downloading, 0.0-1.0

  // Stats
  int totalTokensIn = 0;
  int totalTokensOut = 0;
  int requestCount = 0;
  int pendingRequests = 0;
  double lastTokenSpeed = 0.0; // tok/s
  DateTime bootTime = DateTime.now();

  // Logs (circular, capped at 200)
  final List<String> _logs = [];
  static const int _maxLogs = 200;

  // Device
  DeviceCapabilities? capabilities;

  // --- Getters ---

  FarmConnectionState get connectionState => _connectionState;
  int get tokensEarned => ((totalTokensIn + totalTokensOut) * 0.95).toInt();
  int get totalTokens => totalTokensIn + totalTokensOut;
  int get uptimeSeconds => DateTime.now().difference(bootTime).inSeconds;
  List<String> get logs => List.unmodifiable(_logs);

  // --- Mutations (all call notifyListeners) ---

  set connectionState(FarmConnectionState state) {
    _connectionState = state;
    notifyListeners();
  }

  void recordUsage(TokenUsage usage) {
    totalTokensIn += usage.tokensIn;
    totalTokensOut += usage.tokensOut;
    requestCount++;
    if (usage.inferenceTimeMs > 0) {
      lastTokenSpeed = usage.tokensOut / (usage.inferenceTimeMs / 1000);
    }
    notifyListeners();
  }

  void setModel(String? id, String? name, bool loaded) {
    currentModelId = id;
    currentModelName = name;
    isModelLoaded = loaded;
    notifyListeners();
  }

  void setDownloadProgress(String? modelId, double? progress) {
    downloadingModelId = modelId;
    downloadProgress = progress;
    notifyListeners();
  }

  void addLog(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    _logs.add('[$timestamp] $message');
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }
    notifyListeners();
  }

  void incrementPending() {
    pendingRequests++;
    notifyListeners();
  }

  void decrementPending() {
    if (pendingRequests > 0) pendingRequests--;
    notifyListeners();
  }

  /// Full status snapshot for farm reporting.
  Map<String, dynamic> toStatusJson() => {
        'node_id': nodeId,
        'connection': _connectionState.name,
        'model_id': currentModelId,
        'model_loaded': isModelLoaded,
        'uptime_seconds': uptimeSeconds,
        'tokens_in': totalTokensIn,
        'tokens_out': totalTokensOut,
        'tokens_earned': tokensEarned,
        'request_count': requestCount,
        'pending_requests': pendingRequests,
        'token_speed': double.parse(lastTokenSpeed.toStringAsFixed(1)),
        'capabilities': capabilities?.toJson(),
      };
}
