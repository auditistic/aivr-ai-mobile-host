import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'node_state.dart';
import 'device_capabilities.dart';

/// Persistent WebSocket connection to the AI Farm via Cloudflare gateway.
///
/// Handles auto-login, heartbeat, auto-reconnect with exponential backoff,
/// and bidirectional JSON message passing.
class FarmConnection {
  final String gatewayUrl; // wss://farm.aivr.ai/ws/node
  final NodeState state;
  final void Function(Map<String, dynamic> command)? onCommand;

  WebSocket? _ws;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _intentionalDisconnect = false;

  /// JWT auth token from auth.aivr.site — set before connect().
  String? authToken;

  static const Duration _heartbeatInterval = Duration(seconds: 15);
  static const int _maxReconnectDelaySec = 32;

  FarmConnection({
    required this.gatewayUrl,
    required this.state,
    this.onCommand,
    this.authToken,
  });

  bool get isConnected => _ws != null && state.connectionState == FarmConnectionState.connected;

  /// Connect to the farm. Called once at app start — handles everything from there.
  Future<void> connect() async {
    if (_ws != null) return;
    _intentionalDisconnect = false;
    state.connectionState = FarmConnectionState.connecting;
    state.addLog('Connecting to farm: $gatewayUrl');

    try {
      // Build connection URL with node_id
      final uri = '$gatewayUrl?node_id=${state.nodeId}';

      // Connect with auth token as header if available
      final headers = <String, dynamic>{};
      if (authToken != null && authToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $authToken';
      }

      _ws = await WebSocket.connect(
        uri,
        headers: headers,
      ).timeout(const Duration(seconds: 10));

      _reconnectAttempts = 0;
      state.connectionState = FarmConnectionState.connected;
      state.addLog('Connected to AI Farm');

      // Send hello handshake
      _sendHello();

      // Start heartbeat
      _startHeartbeat();

      // Listen for messages
      _ws!.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (e) {
          state.addLog('WebSocket error: $e');
          _onDisconnected();
        },
        cancelOnError: false,
      );
    } catch (e) {
      state.addLog('Connection failed: $e');
      state.connectionState = FarmConnectionState.disconnected;
      _scheduleReconnect();
    }
  }

  /// Intentional disconnect (app going to background permanently, etc.)
  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    try {
      _send({'type': 'node_goodbye', 'node_id': state.nodeId});
      await _ws?.close(WebSocketStatus.normalClosure);
    } catch (_) {}
    _ws = null;
    state.connectionState = FarmConnectionState.disconnected;
    state.addLog('Disconnected from farm');
  }

  /// Send a message to the farm.
  void _send(Map<String, dynamic> message) {
    try {
      _ws?.add(jsonEncode(message));
    } catch (e) {
      state.addLog('Send error: $e');
    }
  }

  /// Send a typed response back to the farm (for command results).
  void sendResult(String commandId, Map<String, dynamic> result) {
    _send({
      'type': 'command_result',
      'command_id': commandId,
      'node_id': state.nodeId,
      ...result,
    });
  }

  /// Send inference chunk (streaming token).
  void sendInferenceChunk(String requestId, String content, int index) {
    _send({
      'type': 'inference_chunk',
      'request_id': requestId,
      'content': content,
      'index': index,
    });
  }

  /// Send final inference result with usage stats.
  void sendInferenceComplete(String requestId, String fullResponse, TokenUsage usage) {
    _send({
      'type': 'inference_complete',
      'request_id': requestId,
      'response': fullResponse,
      'usage': usage.toJson(),
    });
  }

  /// Report token usage (called after each inference).
  void reportTokens(TokenUsage usage) {
    _send({
      'type': 'token_report',
      'node_id': state.nodeId,
      'usage': usage.toJson(),
      'cumulative': {
        'tokens_in': state.totalTokensIn,
        'tokens_out': state.totalTokensOut,
        'tokens_earned': state.tokensEarned,
        'request_count': state.requestCount,
      },
    });
  }

  /// Report download progress.
  void sendDownloadProgress(String commandId, double progress) {
    _send({
      'type': 'download_progress',
      'command_id': commandId,
      'progress': progress,
    });
  }

  // --- Internal ---

  void _sendHello() {
    _send({
      'type': 'node_hello',
      'node_id': state.nodeId,
      'capabilities': state.capabilities?.toJson(),
      'current_model': state.currentModelId,
      'model_loaded': state.isModelLoaded,
      'status': state.toStatusJson(),
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _send({
        'type': 'heartbeat',
        'node_id': state.nodeId,
        'uptime': state.uptimeSeconds,
        'tokens_in': state.totalTokensIn,
        'tokens_out': state.totalTokensOut,
        'tokens_earned': state.tokensEarned,
        'requests': state.requestCount,
        'pending': state.pendingRequests,
        'token_speed': state.lastTokenSpeed,
        'model_id': state.currentModelId,
        'model_loaded': state.isModelLoaded,
      });
    });
  }

  void _onMessage(dynamic raw) {
    try {
      final message = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = message['type'] as String?;

      if (type == 'pong' || type == 'ack') return; // Heartbeat ack

      state.addLog('Farm command: $type');
      onCommand?.call(message);
    } catch (e) {
      state.addLog('Bad message from farm: $e');
    }
  }

  void _onDisconnected() {
    _ws = null;
    _heartbeatTimer?.cancel();

    if (_intentionalDisconnect) {
      state.connectionState = FarmConnectionState.disconnected;
      return;
    }

    state.connectionState = FarmConnectionState.reconnecting;
    state.addLog('Connection lost — reconnecting...');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delaySec = min(
      pow(2, _reconnectAttempts).toInt(),
      _maxReconnectDelaySec,
    );
    _reconnectAttempts++;

    state.addLog('Reconnect in ${delaySec}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      connect();
    });
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _ws?.close(WebSocketStatus.normalClosure);
    _ws = null;
  }
}
