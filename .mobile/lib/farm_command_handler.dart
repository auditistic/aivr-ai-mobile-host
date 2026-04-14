import 'dart:async';
import 'package:cactus/cactus.dart';
import 'package:flutter/foundation.dart';
import 'node_state.dart';
import 'farm_connection.dart';

/// Processes commands from the AI Farm and orchestrates actions on the
/// Cactus LLM engine.
///
/// Commands are queued and processed sequentially to prevent concurrent
/// model loads or overlapping inference on single-model devices.
/// Exception: `report_status` executes immediately.
class FarmCommandHandler {
  final CactusLM cactusLM;
  final NodeState state;
  late FarmConnection _farm;

  final _commandQueue = <_QueuedCommand>[];
  bool _processing = false;

  FarmCommandHandler({
    required this.cactusLM,
    required this.state,
  });

  /// Must be called after FarmConnection is created.
  void attachFarm(FarmConnection farm) {
    _farm = farm;
  }

  /// Main dispatch — called by FarmConnection.onCommand.
  void handleCommand(Map<String, dynamic> message) {
    final type = message['type'] as String? ?? '';
    final commandId = message['command_id'] as String? ?? '';

    // Immediate commands (bypass queue)
    if (type == 'report_status') {
      _farm.sendResult(commandId, {
        'status': 'ok',
        'data': state.toStatusJson(),
      });
      return;
    }

    // Queued commands
    _commandQueue.add(_QueuedCommand(type: type, commandId: commandId, payload: message));
    _processNext();
  }

  Future<void> _processNext() async {
    if (_processing || _commandQueue.isEmpty) return;
    _processing = true;

    final cmd = _commandQueue.removeAt(0);
    try {
      switch (cmd.type) {
        case 'download_model':
          await _handleDownloadModel(cmd);
          break;
        case 'load_model':
          await _handleLoadModel(cmd);
          break;
        case 'unload_model':
          await _handleUnloadModel(cmd);
          break;
        case 'delete_model':
          await _handleDeleteModel(cmd);
          break;
        case 'inference':
          await _handleInference(cmd);
          break;
        default:
          state.addLog('Unknown command: ${cmd.type}');
          _farm.sendResult(cmd.commandId, {
            'status': 'error',
            'message': 'Unknown command: ${cmd.type}',
          });
      }
    } catch (e) {
      state.addLog('Command ${cmd.type} failed: $e');
      _farm.sendResult(cmd.commandId, {
        'status': 'error',
        'message': e.toString(),
      });
    }

    _processing = false;
    _processNext(); // Process next in queue
  }

  // --- Command Handlers ---

  Future<void> _handleDownloadModel(_QueuedCommand cmd) async {
    final modelId = cmd.payload['model_id'] as String? ?? '';
    if (modelId.isEmpty) {
      _farm.sendResult(cmd.commandId, {'status': 'error', 'message': 'Missing model_id'});
      return;
    }

    state.addLog('Downloading model: $modelId');
    state.setDownloadProgress(modelId, 0.0);

    DateTime lastReport = DateTime.now().subtract(const Duration(seconds: 5));

    try {
      await cactusLM.downloadModel(
        model: modelId,
        downloadProcessCallback: (double? progress, String statusMessage, bool isError) {
          final now = DateTime.now();

          if (progress != null) {
            state.setDownloadProgress(modelId, progress);
          }

          if (isError) {
            state.addLog('Download error: $statusMessage');
            _farm.sendResult(cmd.commandId, {
              'status': 'error',
              'message': statusMessage,
            });
            return;
          }

          // Report progress to farm every 5 seconds
          if (progress != null && now.difference(lastReport).inSeconds >= 5) {
            _farm.sendDownloadProgress(cmd.commandId, progress);
            lastReport = now;
          }
        },
      );

      state.setDownloadProgress(null, null);
      state.addLog('Download complete: $modelId');
      _farm.sendResult(cmd.commandId, {
        'status': 'ok',
        'model_id': modelId,
        'message': 'Download complete',
      });
    } catch (e) {
      state.setDownloadProgress(null, null);
      rethrow;
    }
  }

  Future<void> _handleLoadModel(_QueuedCommand cmd) async {
    final modelId = cmd.payload['model_id'] as String? ?? '';
    final contextSize = cmd.payload['context_size'] as int? ?? 2048;

    if (modelId.isEmpty) {
      _farm.sendResult(cmd.commandId, {'status': 'error', 'message': 'Missing model_id'});
      return;
    }

    state.addLog('Loading model: $modelId (ctx=$contextSize)');

    // Unload current model first
    cactusLM.unload();
    state.setModel(null, null, false);
    await Future.delayed(const Duration(milliseconds: 300));

    await cactusLM.initializeModel(
      params: CactusInitParams(
        model: modelId,
        contextSize: contextSize,
      ),
    );

    final modelName = cmd.payload['model_name'] as String? ?? modelId;
    state.setModel(modelId, modelName, true);
    state.addLog('Model loaded: $modelName');

    _farm.sendResult(cmd.commandId, {
      'status': 'ok',
      'model_id': modelId,
      'message': 'Model loaded and ready',
    });
  }

  Future<void> _handleUnloadModel(_QueuedCommand cmd) async {
    state.addLog('Unloading model');
    cactusLM.unload();
    state.setModel(null, null, false);

    _farm.sendResult(cmd.commandId, {
      'status': 'ok',
      'message': 'Model unloaded',
    });
  }

  Future<void> _handleDeleteModel(_QueuedCommand cmd) async {
    final modelId = cmd.payload['model_id'] as String? ?? '';
    state.addLog('Delete model requested: $modelId');

    // If this model is currently loaded, unload it first
    if (state.currentModelId == modelId) {
      cactusLM.unload();
      state.setModel(null, null, false);
    }

    // TODO: Delete the actual file from storage when Cactus SDK supports it
    _farm.sendResult(cmd.commandId, {
      'status': 'ok',
      'model_id': modelId,
      'message': 'Model unloaded (file deletion pending SDK support)',
    });
  }

  Future<void> _handleInference(_QueuedCommand cmd) async {
    final requestId = cmd.payload['request_id'] as String? ?? cmd.commandId;
    final messages = (cmd.payload['messages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final stream = cmd.payload['stream'] as bool? ?? false;
    final temperature = (cmd.payload['temperature'] as num?)?.toDouble() ?? 0.7;
    final maxTokens = cmd.payload['max_tokens'] as int? ?? 512;

    if (!cactusLM.isLoaded()) {
      _farm.sendResult(cmd.commandId, {
        'status': 'error',
        'request_id': requestId,
        'message': 'No model loaded',
      });
      return;
    }

    state.incrementPending();
    final stopwatch = Stopwatch()..start();

    final chatMessages = messages.map((m) {
      return ChatMessage(
        role: m['role'] as String? ?? 'user',
        content: m['content'] as String? ?? '',
      );
    }).toList();

    try {
      if (!stream) {
        // Non-streaming: generate full response
        final response = await cactusLM.generateCompletion(
          messages: chatMessages,
          params: CactusCompletionParams(
            temperature: temperature,
            maxTokens: maxTokens,
          ),
        );

        stopwatch.stop();

        final usage = TokenUsage(
          tokensIn: response.prefillTokens,
          tokensOut: response.decodeTokens,
          modelId: state.currentModelId ?? 'unknown',
          inferenceTimeMs: stopwatch.elapsedMilliseconds.toDouble(),
        );

        state.recordUsage(usage);
        state.decrementPending();

        // Send result + report tokens
        _farm.sendInferenceComplete(requestId, response.response, usage);
        _farm.reportTokens(usage);

        state.addLog(
          'Inference: ${response.decodeTokens} tok '
          '(${(response.decodeTokens / (stopwatch.elapsedMilliseconds / 1000)).toStringAsFixed(1)} tok/s)',
        );
      } else {
        // Streaming: send chunks
        final streamedResult = await cactusLM.generateCompletionStream(
          messages: chatMessages,
          params: CactusCompletionParams(
            temperature: temperature,
            maxTokens: maxTokens,
          ),
        );

        int chunkIndex = 0;
        final buffer = StringBuffer();

        await for (final chunk in streamedResult.stream) {
          _farm.sendInferenceChunk(requestId, chunk, chunkIndex++);
          buffer.write(chunk);
        }

        final finalResult = await streamedResult.result;
        stopwatch.stop();

        final usage = TokenUsage(
          tokensIn: finalResult.prefillTokens,
          tokensOut: finalResult.decodeTokens,
          modelId: state.currentModelId ?? 'unknown',
          inferenceTimeMs: stopwatch.elapsedMilliseconds.toDouble(),
        );

        state.recordUsage(usage);
        state.decrementPending();

        _farm.sendInferenceComplete(requestId, buffer.toString(), usage);
        _farm.reportTokens(usage);

        state.addLog(
          'Streamed: ${finalResult.decodeTokens} tok in ${chunkIndex} chunks '
          '(${(finalResult.decodeTokens / (stopwatch.elapsedMilliseconds / 1000)).toStringAsFixed(1)} tok/s)',
        );
      }
    } catch (e) {
      state.decrementPending();
      _farm.sendResult(cmd.commandId, {
        'status': 'error',
        'request_id': requestId,
        'message': 'Inference failed: $e',
      });
    }
  }
}

class _QueuedCommand {
  final String type;
  final String commandId;
  final Map<String, dynamic> payload;

  _QueuedCommand({
    required this.type,
    required this.commandId,
    required this.payload,
  });
}
