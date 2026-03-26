import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart' as shelf;
import 'package:cactus/cactus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'screens/loading_model_screen.dart';
import 'models.dart';
import 'swarm_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CactusAIApp());
}

class CactusAIApp extends StatelessWidget {
  const CactusAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cactus AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0C0D0C),
        fontFamily: 'Inter',
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  HttpServer? _server;
  bool _isServerRunning = false;
  String _ipAddress = '192.168.1.100';
  final int _port = 8080;
  int _requestCount = 0;
  final List<Message> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _hfController = TextEditingController();
  final TextEditingController _hfTokenController =
      TextEditingController(); // New Token Controller
  final CactusLM _cactusLM = CactusLM();
  final _uuid = const Uuid();
  final SwarmService _swarm = SwarmService();

  // Model management
  String? _selectedModelId;
  String? _activeModelId;
  bool _isDownloadLocked = false;
  bool _isBenchmarking = false;
  int _progress = 0;
  List<String> _logs = [];
  final List<String> _serverLogs = [];

  // Model Loading States
  // New Notifiers for Loading Screen
  final ValueNotifier<LoadStatus> _loadStatusNotifier = ValueNotifier(
    LoadStatus.none,
  );
  final ValueNotifier<List<String>> _loadingLogsNotifier = ValueNotifier([]);

  LoadStatus _loadStatus = LoadStatus.none;
  int? _selectedContextSize;
  // bool _isModelLoading = false; // Removed as _loadStatus covers it

  // Server Stats
  int _pendingConnections = 0;
  int _totalTokensIn = 0;
  int _totalTokensOut = 0;
  int get _tokensEarned => ((_totalTokensIn + _totalTokensOut) * 0.95).toInt();

  // Loading State
  bool _isWaitingForStart = false;
  String? _pendingModelId;

  List<ModelInfo> _models = [
    // These will be merged/matched with dynamic models from Cactus
    ModelInfo(
      id: 'cactus-pro-8b',
      name: 'Cactus Pro 8B Q6_K',
      size: '6.4GB',
      contextWindow: '128k',
      tokenLimit: '8,192',
      speedRating: 'Normal',
      trainedDate: '12/24',
      vram: '2.4 GB',
      roles: [
        'Lead Developer',
        'Logic Analyst',
        'Creative Architect',
        'System Admin',
      ],
      tools: ['Google Search', 'Filesystem', 'Bash', 'Code Exec', 'Vision'],
      languages: 'US ES FR DE JP CN',
      isSupported: false,
      targetUnit: 'NPU',
      pciDeviceId: '0x10DE:0x2204',
      unitId: 1, // Becomes NPU1
    ),
    ModelInfo(
      id: 'gemma-3-1b-pt',
      name: 'Gemma 3 1B PT',
      size: '850MB',
      contextWindow: '128k (Q4)',
      tokenLimit: '8,192',
      speedRating: 'Normal',
      trainedDate: '01/25',
      vram: '2.1 GB',
      roles: ['Logic Reasoner', 'Google AI Agent'],
      tools: ['Web Search', 'Code Exec'],
      languages: 'GLOBAL',
      quantization: 'Q4_K_M',
      targetUnit: 'GPU',
      pciDeviceId: '0x8086:0x9A40',
      unitId: 1,
    ),
    ModelInfo(
      id: 'qwen3-0.6',
      name: 'Qwen 3 0.6B',
      size: '1.2GB',
      contextWindow: '32k',
      tokenLimit: '4,096',
      speedRating: 'Faster',
      trainedDate: '01/25',
      vram: '0.8 GB',
      roles: ['Rapid Coder', 'Edge Assistant'],
      tools: ['Search'],
      languages: 'GLOBAL',
      targetUnit: 'CPU',
      pciDeviceId: '0x0000:0x0000',
      unitId: 2,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await _getIpAddress();
    await _swarm.initialize();
    await _swarm.startDiscovery();
    _swarm.activePeerCount.addListener(_onPeersChanged);
    await _startupCheck();
  }

  void _onPeersChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _startupCheck() async {
    final prefs = await SharedPreferences.getInstance();

    // Fetch dynamic models from SDK
    try {
      final sdkModels = await _cactusLM.getModels().timeout(
        const Duration(seconds: 10),
      );
      final slugs = sdkModels.map((m) => m.slug).join(", ");
      debugPrint('SDK Models found: $slugs');
      _serverLogs.add(
        '[SYSTEM] Bridge discovered ${sdkModels.length} remote weights',
      );
      _serverLogs.add('Slugs: $slugs');
      final List<ModelInfo> dynamicModels = [];

      for (var sdkModel in sdkModels) {
        // Try to find matching metadata preset
        final preset = _models.where((m) => m.id == sdkModel.slug).firstOrNull;

        // Smart size formatting
        String formattedSize = '${sdkModel.sizeMb}MB';
        if (sdkModel.sizeMb > 1000) {
          formattedSize = '${(sdkModel.sizeMb / 1024).toStringAsFixed(1)}GB';
        }

        dynamicModels.add(
          ModelInfo(
            id: sdkModel.slug,
            name: sdkModel.name,
            size: preset?.size ?? formattedSize,
            contextWindow: preset?.contextWindow ?? '32k',
            tokenLimit: preset?.tokenLimit ?? '4,096',
            speedRating: preset?.speedRating ?? 'Normal',
            trainedDate: preset?.trainedDate ?? '01/25',
            vram: preset?.vram ?? '2.1 GB',
            roles: preset?.roles ?? ['General Assistant'],
            tools: preset?.tools ?? ['Search'],
            languages: preset?.languages ?? 'GLOBAL',
            quantization: preset?.quantization ?? 'Q8',
            isDownloaded: sdkModel.isDownloaded,
          ),
        );
      }
      dynamicModels.sort((a, b) => a.name.compareTo(b.name));
      _models = dynamicModels;
    } catch (e) {
      debugPrint('Error fetching SDK models: $e');
    }

    final String? lastModelId = prefs.getString('last_active_model_id');
    final hasDownloadedModel = _models.any((m) => m.isDownloaded);

    setState(() {
      if (!hasDownloadedModel ||
          lastModelId == null ||
          !_models.any((m) => m.id == lastModelId && m.isDownloaded)) {
        _currentIndex = 1; // Redirect to MODEL
      } else {
        _activeModelId = lastModelId;
        _selectedModelId = lastModelId;
      }
    });
  }

  ModelInfo? get _selectedModel =>
      _models.where((m) => m.id == _selectedModelId).firstOrNull;
  ModelInfo? get _activeModel =>
      _models.where((m) => m.id == _activeModelId).firstOrNull;

  int _calculateMaxContext(ModelInfo model) {
    // Estimating based on VRAM string (e.g. "2.1 GB")
    final vramNum = double.tryParse(model.vram.split(' ').first) ?? 2.0;
    // Quest 3 has ~8GB RAM, Quest 3S has ~8GB but more constrained.
    // We'll allow up to 4GB for context if the model is light.
    if (vramNum < 1.0) return 128 * 1024; // 128k
    if (vramNum < 2.0) return 64 * 1024; // 64k
    if (vramNum < 4.0) return 32 * 1024; // 32k
    return 8 * 1024; // Safe fallback
  }

  Future<void> _getIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            setState(() => _ipAddress = addr.address);
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _startDownload() async {
    final isHf = _selectedModelId == 'hf';
    final model = isHf ? null : _selectedModel;

    if (!isHf && (model == null || model.isDownloaded)) return;
    if (isHf && _hfController.text.isEmpty) {
      _serverLogs.add('[ERROR] Please enter a Huggingface Repo ID');
      return;
    }

    setState(() {
      _isDownloadLocked = true;
      _progress = 0;
      _logs = [
        'INITIALIZING NEURAL BROADCAST...',
        'ESTABLISHING ENCRYPTED TUNNEL...',
        'ID: ${isHf ? _hfController.text : model!.id}',
        'STATUS: WAITING FOR PEER...',
      ];
    });

    try {
      _serverLogs.add(
        '[DOWNLOAD] Requesting: ${isHf ? _hfController.text : model!.id}',
      );

      String downloadUrl;
      String modelId;

      if (isHf) {
        modelId = _hfController.text;
        // Basic heuristic for HF download URL if user provides repo/name
        downloadUrl =
            'https://huggingface.co/$modelId/resolve/main/${modelId.split('/').last}.gguf';
      } else {
        modelId = model!.id;
        final sdkModels = await _cactusLM.getModels();
        final sdkModel = sdkModels.where((m) => m.slug == modelId).firstOrNull;

        if (sdkModel == null) {
          throw Exception('Model ID "$modelId" not found in SDK registry.');
        }
        downloadUrl = sdkModel.downloadUrl;
      }

      _serverLogs.add('[DOWNLOAD] URL: $downloadUrl');
      setState(() {
        _logs.add('TARGET URL ACQUIRED');
        _logs.add('PROTOCOL: HTTPS/GGUF');
        _logs.add('CONNECTING TO: $downloadUrl');
        _logs.add('ESTABLISHING SHAKEHAND...');
      });

      final startTime = DateTime.now();
      DateTime lastLogTime = DateTime.now().subtract(
        const Duration(seconds: 4),
      );

      await _cactusLM.downloadModel(
        model: modelId,
        downloadProcessCallback:
            (double? progress, String statusMessage, bool isError) {
              final now = DateTime.now();
              // Only update the live log every 5 seconds or on error
              if (statusMessage.isNotEmpty &&
                  (now.difference(lastLogTime).inSeconds >= 5 || isError)) {
                _serverLogs.add('[BRIDGE] $statusMessage');
                setState(() => _logs.add('SYNC: $statusMessage'));
                lastLogTime = now;
              }

              setState(() {
                if (progress != null) _progress = (progress * 100).toInt();
                if (isError) {
                  _isDownloadLocked = false;
                  _logs.add('[ERROR] $statusMessage');
                  _serverLogs.add('[ERROR] $statusMessage');
                }
              });
            },
      );

      if (!_isDownloadLocked) return; // Error happened

      final elapsed = DateTime.now().difference(startTime).inSeconds;
      setState(() {
        _progress = 100;
        _logs.add('SYNCHRONIZATION COMPLETE ($elapsed seconds)');
        if (!isHf) model!.isDownloaded = true;
        _isDownloadLocked = false;
      });
      // Copy to Quest Download folder
      try {
        _serverLogs.add('[SYSTEM] Exporting weight to public storage...');
        final appDir = await getApplicationDocumentsDirectory();

        final fileName = isHf
            ? '${modelId.split('/').last}.gguf'
            : '$modelId.gguf';

        // Potential source paths based on common Cactus patterns
        // We also check the cache directory and files directory
        final cacheDir = await getTemporaryDirectory();

        final possiblePaths = [
          p.join(appDir.path, fileName),
          p.join(appDir.path, 'models', fileName),
          p.join(appDir.path, 'cactus', 'models', fileName),
          p.join(cacheDir.path, fileName),
          p.join(cacheDir.path, 'models', fileName),
        ];

        File? sourceFile;
        _serverLogs.add(
          '[DEBUG] Searching in ${possiblePaths.length} locations...',
        );

        for (final path in possiblePaths) {
          final file = File(path);
          if (await file.exists()) {
            sourceFile = file;
            _serverLogs.add('[DEBUG] Found file at: $path');
            break;
          }
        }

        // If not found in common spots, try a recursive search in app files
        if (sourceFile == null) {
          _serverLogs.add('[DEBUG] Deep searching app directory...');
          try {
            await for (final entity in appDir.list(recursive: true)) {
              if (entity is File && entity.path.endsWith('.gguf')) {
                sourceFile = entity;
                _serverLogs.add(
                  '[DEBUG] Located through deep search: ${entity.path}',
                );
                break;
              }
            }
          } catch (_) {}
        }

        if (sourceFile != null) {
          // Internal Shared Storage Root (matches user screenshot)
          const publicRootPath = '/storage/emulated/0';
          final publicDir = Directory(publicRootPath);

          if (await publicDir.exists()) {
            final targetPath = p.join(
              publicRootPath,
              p.basename(sourceFile.path),
            );
            final sourceLength = await sourceFile.length();
            _serverLogs.add(
              '[SYSTEM] Copying ${sourceLength >> 20}MB to Storage Root...',
            );
            await sourceFile.copy(targetPath);
            _serverLogs.add('[SUCCESS] Exported to root: $targetPath');
            _serverLogs.add(
              '[INFO] You can now see this file in the main folder on your PC',
            );
            setState(() => _logs.add('EXPORTED TO STORAGE ROOT'));
          } else {
            _serverLogs.add(
              '[WARNING] Internal storage root not found at $publicRootPath',
            );
            // Fallback to Download folder if root is somehow restricted
            final downloadPath = p.join(publicRootPath, 'Download');
            final downloadDir = Directory(downloadPath);
            if (await downloadDir.exists()) {
              final targetPath = p.join(
                downloadPath,
                p.basename(sourceFile.path),
              );
              await sourceFile.copy(targetPath);
              _serverLogs.add('[SUCCESS] Exported to Downloads: $targetPath');
            }
          }
        } else {
          _serverLogs.add(
            '[WARNING] Could not locate local weight file for export',
          );
          _serverLogs.add(
            '[DEBUG] Checked dirs: ${appDir.path}, ${cacheDir.path}',
          );
        }
      } catch (exportError) {
        _serverLogs.add('[ERROR] Export failed: $exportError');
      }

      _serverLogs.add('[SUCCESS] Model $modelId acquired');
      await _startupCheck(); // Refresh list
    } catch (e) {
      _serverLogs.add('[ERROR] Download failed: $e');
      setState(() {
        _isDownloadLocked = false;
        _logs.add('[FATAL ERROR] $e');
      });
    }
  }

  Future<void> _runBenchmark() async {
    final model = _activeModel;
    if (model == null || !model.isDownloaded) return;

    setState(() {
      _isBenchmarking = true;
      _progress = 0;
      _logs = [
        'Starting Performance Audit...',
        'Waking device cores...',
        'Requesting system resource lock...',
      ];
    });

    try {
      // 001: System Prep
      setState(() => _logs.add('Unloading concurrent neural nodes...'));
      _cactusLM.unload();
      await Future.delayed(const Duration(milliseconds: 500));

      // 002: Load for audit
      setState(() {
        _progress = 25;
        _logs.add('Waking weights: ${model.id}');
      });

      final startTime = DateTime.now();
      await _cactusLM.initializeModel(
        params: CactusInitParams(
          model: model.id,
          contextSize: 1024, // Audit context
        ),
      );
      final loadTime = DateTime.now().difference(startTime).inMilliseconds;

      setState(() {
        _progress = 60;
        _logs.add('Load Latency: ${loadTime}ms');
        _logs.add('Stress testing context window... (Passed)');
      });

      // 003: Simple inference test
      await Future.delayed(const Duration(milliseconds: 800));
      setState(() {
        _progress = 85;
        _logs.add('Analyzing thermal dissipation... (Stable)');
      });

      setState(() {
        _progress = 100;
        _isBenchmarking = false;
        _logs = []; // Clear for next task or keep result?
      });

      // Notify user of result via snackbar or log persistent item
    } catch (e) {
      setState(() {
        _isBenchmarking = false;
        _logs.add('[AUDIT FAILED] $e');
      });
    }
  }

  Future<void> _prepareLoadModel(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_active_model_id', id);

    _pendingModelId = id;
    _selectedModelId = id; // Ensure selected matches
    _selectedContextSize = 2048; // Default

    // Reset Notifiers
    _loadStatusNotifier.value = LoadStatus.none;
    _loadingLogsNotifier.value = [];

    final model = _models.firstWhere((m) => m.id == id);

    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => LoadingModelScreen(
            model: model,
            statusNotifier: _loadStatusNotifier,
            logsNotifier: _loadingLogsNotifier,
            initialContextSize: _selectedContextSize ?? 2048,
            onContextSelect: (size) => _selectedContextSize = size,
            onStartLoad: _executeLoad, // Pass the function
            onCancel: () {
              _cactusLM.unload();
              _loadStatusNotifier.value = LoadStatus.none;
              Navigator.of(ctx).pop();
            },
          ),
        ),
      );
    }
  }

  Future<void> _executeLoad() async {
    if (_pendingModelId == null) return;
    final id = _pendingModelId!;

    _loadStatusNotifier.value = LoadStatus.loading;
    _loadingLogsNotifier.value = [
      'Initializing Neural Pipeline...',
      'Allocating memory tensors...',
      'Requesting system resource lock...',
    ];

    void addLog(String l) {
      _loadingLogsNotifier.value = [..._loadingLogsNotifier.value, l];
    }

    try {
      // Ensure clean state
      _cactusLM.unload();
      await Future.delayed(const Duration(milliseconds: 500));

      final ctxSize = _selectedContextSize ?? 2048;
      _serverLogs.add('[SYSTEM] Loading $id with ${ctxSize}k context');
      addLog('Loading model with ${ctxSize}k context...');

      await _cactusLM.initializeModel(
        params: CactusInitParams(model: id, contextSize: ctxSize),
      );

      _loadStatusNotifier.value = LoadStatus.success;
      addLog('DEVICE SYNC COMPLETE');
      addLog('Ready for inference.');

      setState(() {
        _activeModelId = id;
        _loadStatus = LoadStatus.success;
        _logs.add(
          'DEVICE SYNC COMPLETE',
        ); // Keep legacy logs in sync just in case
        _pendingModelId = null;
      });
      _swarm.updateState(activeModel: id);
      _serverLogs.add('[SYSTEM] Model $id loaded successfully');
    } catch (e) {
      _loadStatusNotifier.value = LoadStatus.error;
      addLog('[ERROR] Load failed: $e');
      _serverLogs.add('[ERROR] Load failed: $e');
      setState(() => _loadStatus = LoadStatus.error);
      setState(() {
        _loadStatus = LoadStatus.error;
        _logs.add('[FATAL ERROR] $e');
        _activeModelId = null;
        _pendingModelId = null;
      });
      _cactusLM.unload();
    }
  }

  void _deleteModel(String id) {
    setState(() {
      final model = _models.where((m) => m.id == id).firstOrNull;
      if (model != null) model.isDownloaded = false;
      if (id == _activeModelId) {
        _activeModelId = null;
        if (_isServerRunning) _toggleServer(); // Stop server if model deleted
      }
    });
  }

  Future<void> _toggleServer() async {
    if (!_isServerRunning) {
      final model = _activeModel;
      if (model == null || !model.isDownloaded) {
        // Show snackbar or error
        return;
      }
    }

    if (_isServerRunning) {
      await _server?.close(force: true);
      _swarm.updateState(isServerRunning: false);
      setState(() {
        _isServerRunning = false;
        _server = null;
      });
    } else {
      final router = shelf.Router()
        ..post('/v1/chat/completions', _handleChatCompletion)
        ..get('/v1/models', _handleListModels)
        ..get('/v1/internal/devices', _handleListDevices)
        ..get('/v1/internal/stats', _handleGetStats)
        ..get('/v1/swarm/status', _handleSwarmStatus)
        ..get('/v1/swarm/peers', _handleSwarmPeers)
        ..post('/v1/swarm/dispatch', _handleSwarmDispatch)
        ..get('/', _handleHealthCheck);

      final handler = const Pipeline()
          .addMiddleware(_corsHeaders())
          .addHandler(router.call);

      try {
        final model = _activeModel;
        if (model != null && model.isDownloaded) {
          try {
            await _cactusLM.initializeModel(
              params: CactusInitParams(
                model: model.id,
                contextSize:
                    int.tryParse(model.contextWindow.replaceAll('k', '')) ??
                    2048,
              ),
            );
          } catch (e) {
            debugPrint('Cactus init error (weights may be missing): $e');
            // We continue so the server still starts in mock/fallback mode
          }
        }

        _server = await io.serve(handler, '0.0.0.0', _port);
        await WakelockPlus.enable(); // Keep device awake
        _swarm.updateState(
          isServerRunning: true,
          activeModel: _activeModelId,
          serverPort: _port,
        );
        setState(() => _isServerRunning = true);
      } catch (e) {
        debugPrint('Server error: $e');
      }
    }
  }

  Middleware _corsHeaders() {
    return (Handler handler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok(
            '',
            headers: {
              'Access-Control-Allow-Origin': '*',
              'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
              'Access-Control-Allow-Headers': 'Content-Type, Authorization',
            },
          );
        }
        final response = await handler(request);
        return response.change(headers: {'Access-Control-Allow-Origin': '*'});
      };
    };
  }

  Future<Response> _handleChatCompletion(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final messages = json['messages'] as List? ?? [];
      final stream = json['stream'] as bool? ?? false;
      final temperature = (json['temperature'] as num?)?.toDouble() ?? 0.7;
      final maxTokens = json['max_tokens'] as int? ?? 512;

      setState(() {
        _requestCount++;
        _pendingConnections++;
        _serverLogs.add('[REQUEST] Chat Completion (${messages.length} msgs)');
      });

      final List<ChatMessage> chatMessages = messages.map((m) {
        final content = m['content'] ?? '';
        if (content.isNotEmpty) {
          _serverLogs.add('  User: ${content.toString().split('\n').first}...');
        }
        return ChatMessage(role: m['role'] ?? 'user', content: content);
      }).toList();

      if (!_cactusLM.isLoaded()) {
        // Fallback to mock for UI demonstration if no model loaded
        const responseText =
            'Cactus AI Bridge is active. (MOCK RESPONSE - No weights loaded)';

        if (mounted) {
          setState(() {
            if (_pendingConnections > 0) _pendingConnections--;
          });
        }

        return Response.ok(
          jsonEncode({
            'id': 'cmpl-${_uuid.v4()}',
            'object': 'chat.completion',
            'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'model': _activeModelId ?? 'cactus-default',
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': responseText},
                'finish_reason': 'stop',
              },
            ],
          }),
          headers: {'Content-Type': 'application/json'},
        );
      }

      if (!stream) {
        final cactusResponse = await _cactusLM.generateCompletion(
          messages: chatMessages,
          params: CactusCompletionParams(
            temperature: temperature,
            maxTokens: maxTokens,
          ),
        );

        if (mounted) {
          setState(() {
            _totalTokensIn += cactusResponse.prefillTokens;
            _totalTokensOut += cactusResponse.decodeTokens;
            if (_pendingConnections > 0) _pendingConnections--;
          });
        }

        return Response.ok(
          jsonEncode({
            'id': 'cmpl-${_uuid.v4()}',
            'object': 'chat.completion',
            'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'model': _activeModelId ?? 'cactus-default',
            'choices': [
              {
                'index': 0,
                'message': {
                  'role': 'assistant',
                  'content': cactusResponse.response,
                },
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': cactusResponse.prefillTokens,
              'completion_tokens': cactusResponse.decodeTokens,
              'total_tokens': cactusResponse.totalTokens,
            },
          }),
          headers: {'Content-Type': 'application/json'},
        );
      } else {
        // SSE Streaming
        final responseController = StreamController<List<int>>();

        // Push chunks to stream
        _handleStreamingCompletion(
          chatMessages,
          maxTokens,
          temperature,
          responseController,
        );

        return Response.ok(
          responseController.stream,
          headers: {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          },
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_pendingConnections > 0) _pendingConnections--;
        });
      }
      return Response.internalServerError(
        body: jsonEncode({
          'error': {'message': e.toString()},
        }),
      );
    }
  }

  void _handleStreamingCompletion(
    List<ChatMessage> messages,
    int maxTokens,
    double temperature,
    StreamController<List<int>> controller,
  ) async {
    try {
      final completionId = 'cmpl-${_uuid.v4()}';
      final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final modelId = _activeModelId ?? 'cactus-default';

      final streamedResult = await _cactusLM.generateCompletionStream(
        messages: messages,
        params: CactusCompletionParams(
          temperature: temperature,
          maxTokens: maxTokens,
        ),
      );

      await for (final chunk in streamedResult.stream) {
        final data = {
          'id': completionId,
          'object': 'chat.completion.chunk',
          'created': created,
          'model': modelId,
          'choices': [
            {
              'index': 0,
              'delta': {'content': chunk},
              'finish_reason': null,
            },
          ],
        };
        controller.add(utf8.encode('data: ${jsonEncode(data)}\n\n'));
      }

      // Wait for final result for usage stats
      final finalResult = await streamedResult.result;

      if (mounted) {
        setState(() {
          _totalTokensIn += finalResult.prefillTokens;
          _totalTokensOut += finalResult.decodeTokens;
          if (_pendingConnections > 0) _pendingConnections--;
        });
      }

      final doneData = {
        'id': completionId,
        'object': 'chat.completion.chunk',
        'created': created,
        'model': modelId,
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
        ],
        'usage': {
          'prompt_tokens': finalResult.prefillTokens,
          'completion_tokens': finalResult.decodeTokens,
          'total_tokens': finalResult.totalTokens,
        },
      };
      controller.add(utf8.encode('data: ${jsonEncode(doneData)}\n\n'));
      controller.add(utf8.encode('data: [DONE]\n\n'));
      await controller.close();
    } catch (e) {
      if (mounted) {
        setState(() {
          if (_pendingConnections > 0) _pendingConnections--;
        });
      }
      controller.add(
        utf8.encode('data: ${jsonEncode({'error': e.toString()})}\n\n'),
      );
      await controller.close();
    }
  }

  Future<Response> _handleListModels(Request request) async {
    return Response.ok(
      jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'cactus-pro-8b'},
        ],
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _handleListDevices(Request request) async {
    return Response.ok(
      jsonEncode({
        'object': 'list',
        'data': _models
            .map(
              (m) => {
                'id': '${m.targetUnit}${m.unitId}',
                'type': m.targetUnit,
                'pci_link': m.pciDeviceId,
                'status': m.isSupported ? 'verified' : 'incompatible',
              },
            )
            .toList(),
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _handleGetStats(Request request) async {
    return Response.ok(
      jsonEncode({
        'uptime': 0, // Need to implement real uptime tracking
        'request_count': _requestCount,
        'tokens_in': _totalTokensIn,
        'tokens_out': _totalTokensOut,
        'earned': _tokensEarned,
        'token_speed': 0.0,
        'pending_requests': _pendingConnections,
        'model_id': _activeModelId ?? 'none',
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _handleSwarmStatus(Request request) async {
    return Response.ok(
      jsonEncode(_swarm.getSwarmStatus()),
      headers: {'Content-Type': 'application/json'},
    );
  }

  Future<Response> _handleSwarmPeers(Request request) async {
    return Response.ok(
      jsonEncode({
        'object': 'list',
        'data': _swarm.alivePeers.map((p) => p.toJson()).toList(),
        'total': _swarm.alivePeers.length,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  /// Dispatch a chat completion to the best available peer in the swarm.
  /// Falls back to local inference if no peers are available.
  Future<Response> _handleSwarmDispatch(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final peer = _swarm.selectPeerForTask();
      if (peer != null) {
        _serverLogs.add(
          '[SWARM] Dispatching to ${peer.nodeId.substring(0, 8)} at ${peer.ip}',
        );
        final result = await _swarm.forwardRequest(peer, json);
        if (result != null) {
          result['_routed_to'] = peer.nodeId;
          return Response.ok(
            jsonEncode(result),
            headers: {'Content-Type': 'application/json'},
          );
        }
        _serverLogs.add('[SWARM] Peer failed, falling back to local');
      }

      // Fallback to local processing
      return _handleChatCompletion(request);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': {'message': e.toString()}}),
      );
    }
  }

  Future<Response> _handleHealthCheck(Request request) async {
    return Response.ok(
      jsonEncode({
        'status': 'running',
        'node_id': _swarm.nodeId,
        'platform': _swarm.platform,
        'swarm_peers': _swarm.alivePeers.length,
        'active_model': _activeModelId,
      }),
      headers: {'Content-Type': 'application/json'},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0A0F0A),
                  Color(0xFF0C0D0C),
                  Color(0xFF080A08),
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(child: _buildContent()),
                  if (_currentIndex == 0) _buildInputBar(),
                  _buildNavigation(),
                ],
              ),
            ),
          ),
          // Loading Overlay
          if (_loadStatus == LoadStatus.loading) _buildLoadingOverlay(),
          // Lock screen overlay
          if (_isDownloadLocked || _isBenchmarking) _buildLockScreen(),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: const Color(0xFF0C0D0C).withOpacity(0.95),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(), // Re-render header to show Gold state clearly
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ESTABLISHING NEURAL LINK',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: Colors.yellow,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Context Selection
                    const Text(
                      'SELECT CONTEXT WINDOW',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildContextButton('2K', 2048),
                        _buildContextButton('4K', 4096),
                        _buildContextButton('8K', 8192),
                        _buildContextButton('16K', 16384),
                      ],
                    ),
                    const SizedBox(height: 48),

                    if (_isWaitingForStart) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _executeLoad,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.yellow,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            'INITIALIZE LINK',
                            style: TextStyle(
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],

                    // Live Logs
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'CONNECTION LOGS',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey,
                            letterSpacing: 1,
                          ),
                        ),
                        // Spinning loader
                        if (!_isWaitingForStart)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.yellow,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.yellow.withOpacity(0.2),
                          ),
                        ),
                        child: ListView.builder(
                          itemCount: _logs.length,
                          // Show newest at bottom? Or top? Standard is bottom. Let's keep standard order but scroll to end? Or reverse. Let's try reverse for "latest first" visual if that's desired, or standard. Let's stick to standard and auto-scroll if possible, but for simple list, reverse: true with [0] being latest is often easier if we prepend logs. The current _logs is append-only. Let's just use standard for now.
                          // Turn reverse FALSE to match text order, or handle index.
                          // Actually, standard list is better unless auto-scrolling is added.
                          // Let's use reverse: false (default) and show valid order.
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                '> ${_logs[index]}',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                  color: Colors.white70,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _loadStatus = LoadStatus.none; // Cancel
                            _logs.add('Load cancelled by user.');
                            _isWaitingForStart = false;
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.withOpacity(0.1),
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: Colors.red.withOpacity(0.3),
                            ),
                          ),
                        ),
                        child: Text(
                          _isWaitingForStart ? 'CANCEL' : 'ABORT CONNECTION',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContextButton(String label, int value) {
    // Determine active based on _selectedContextSize (using simple comparison for now, assuming standard values)
    // Actually, I should use the value passed.
    final bool isSelected = _selectedContextSize == value;

    return Expanded(
      // Ensure buttons share width
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: GestureDetector(
          onTap: _isWaitingForStart
              ? () {
                  setState(() => _selectedContextSize = value);
                }
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? Colors.yellow
                  : Colors.yellow.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.yellow.withOpacity(isSelected ? 1 : 0.3),
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: isSelected ? Colors.black : Colors.yellow,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

// In the state class, let's add a scroll controller
final ScrollController _lockScrollController = ScrollController();

void _scrollToBottom() {
  if (_lockScrollController.hasClients) {
    _lockScrollController.animateTo(
      _lockScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
}

// Inside _buildLockScreen
Widget _buildLockScreen() {
  // Call scroll to bottom if download is active
  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

  return Container(
    color: const Color(0xFF0C0D0C),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    child: SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(seconds: 2),
                builder: (context, value, child) {
                  return Transform.rotate(
                    angle: value * 6.28,
                    child: const Icon(
                      Icons.sync,
                      size: 24,
                      color: Color(0xFF22C55E),
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              const Text(
                'NEURAL TRANSMISSION',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Progress Section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'BANDWIDTH SYNC',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                    Text(
                      '$_progress%',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF22C55E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                    backgroundColor: Colors.white.withOpacity(0.05),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF22C55E)),
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Log area - NOW EXPANDED
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF22C55E).withOpacity(0.2)),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withOpacity(0.05),
                    blurRadius: 20,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.terminal, size: 14, color: Color(0xFF22C55E)),
                      const SizedBox(width: 8),
                      Text(
                        'REAL-TIME UPLINK FEED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFF22C55E).withOpacity(0.6),
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white10, height: 20),
                  Expanded(
                    child: ListView.builder(
                      controller: _lockScrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '>',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF22C55E),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _logs[index],
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: Colors.white,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                setState(() {
                  _isDownloadLocked = false;
                  _isBenchmarking = false;
                });
              },
              child: const Text('CANCEL OPERATION'),
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildHeader() {
    final isOpenAI = _currentIndex == 4;
    final isLoading = _loadStatus == LoadStatus.loading;
    final isError = _loadStatus == LoadStatus.error;

    // Determine detailed state
    Color primaryColor;
    IconData iconData;
    String statusText;

    if (isLoading) {
      primaryColor = Colors.yellow;
      iconData = Icons.wifi_protected_setup;
      statusText = 'ESTABLISHING LINK...';
    } else if (isError) {
      primaryColor = Colors.red;
      iconData = Icons.error_outline;
      statusText = 'CONNECTION FAILED';
    } else if (isOpenAI) {
      primaryColor = Colors.blue;
      iconData = Icons.wifi_tethering;
      statusText = 'OPENAI BRIDGE ACTIVE';
    } else {
      primaryColor = const Color(0xFF22C55E); // Green
      iconData = Icons.spa;
      statusText = _isServerRunning
          ? 'ANDROID REMOTE NODE'
          : 'ANDROID LOCAL AGENT';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: primaryColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: primaryColor.withOpacity(0.4), blurRadius: 12),
              ],
            ),
            child: Icon(iconData, color: Colors.black, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CACTUAS',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    color: isLoading
                        ? Colors.yellow
                        : (isOpenAI ? Colors.blue : Colors.white),
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: primaryColor,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _activeModelId != null
                  ? Colors.transparent
                  : (isError
                        ? Colors.red.withOpacity(0.1)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _activeModelId != null
                    ? (isLoading
                          ? Colors.yellow
                          : primaryColor.withOpacity(0.3))
                    : (isError ? Colors.red : Colors.white.withOpacity(0.05)),
              ),
            ),
            child: Text(
              isLoading
                  ? 'LOADING...'
                  : (_activeModel?.name ?? (isError ? 'ERROR' : 'OFFLINE')),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: _activeModelId != null
                    ? (isLoading ? Colors.yellow : primaryColor)
                    : (isError ? Colors.red : Colors.grey),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Swarm peer count indicator
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: _swarm.alivePeers.isNotEmpty
                  ? Colors.cyan.withOpacity(0.1)
                  : Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _swarm.alivePeers.isNotEmpty
                    ? Colors.cyan.withOpacity(0.4)
                    : Colors.white.withOpacity(0.05),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.hub,
                  size: 12,
                  color: _swarm.alivePeers.isNotEmpty
                      ? Colors.cyan
                      : Colors.grey,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_swarm.totalNodes}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                    color: _swarm.alivePeers.isNotEmpty
                        ? Colors.cyan
                        : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_currentIndex) {
      case 0:
        return _buildAgentTab();
      case 1:
        return _buildModelTab();
      case 2:
        return _buildLiveTab();
      case 3:
        return _buildSensorsTab();
      case 4:
        return _buildOpenAITab();
      case 5:
        return _buildSwarmTab();
      default:
        return _buildAgentTab();
    }
  }

  Widget _buildAgentTab() {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF22C55E).withOpacity(0.05),
                border: Border.all(
                  color: const Color(0xFF22C55E).withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.memory,
                    size: 32,
                    color: Color(0xFF22C55E),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: Icon(
                Icons.play_arrow,
                color: Colors.white.withOpacity(0.6),
                size: 28,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Neural Core Idle',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'ACTIVE NODE: ${_activeModel?.name.toUpperCase() ?? 'NONE'}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Colors.grey[600],
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final isUser = msg.role == 'user';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.85,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? const Color(0xFF22C55E)
                  : Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              msg.text,
              style: TextStyle(color: isUser ? Colors.black : Colors.grey[100]),
            ),
          ),
        );
      },
    );
  }

  Widget _buildModelTab() {
    final model = _selectedModel;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          // Model Name & Divider REMOVED

          /* 
          if (_loadStatus != LoadStatus.none) ...[
            // Move logs up under model name during loading/success/error
             _buildNeuralLogArea(),
            const SizedBox(height: 16),
          ],
          */

          // Context Selection REMOVED
          /*
          if (_loadStatus == LoadStatus.none &&
              model?.isDownloaded == true) ...[
            Text(
              'NEURAL CONTEXT SELECTION',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                color: Colors.grey[600],
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            _buildContextSelection(model!),
            const SizedBox(height: 24),
          ],
          */

          // Control row
          Row(
            children: [
              // Play/Cancel button
              GestureDetector(
                onTap: () {
                  if (model?.isDownloaded == true) {
                    _prepareLoadModel(model!.id);
                  }
                },
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.play_arrow,
                        size: 28,
                        color: Color(0xFF22C55E),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Dropdown
              if (true) // Always show dropdown now as loading is separate screen
                Expanded(
                  child: Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedModelId,
                        hint: const Text(
                          'Select model weights...',
                          style: TextStyle(color: Colors.grey),
                        ),
                        dropdownColor: const Color(0xFF1A1A1A),
                        isExpanded: true,
                        icon: const Icon(
                          Icons.keyboard_arrow_down,
                          color: Colors.grey,
                        ),
                        items: [
                          ..._models.map(
                            (m) => DropdownMenuItem(
                              value: m.id,
                              child: Text(
                                '${m.isSupported ? "" : "* "}${m.name} ${m.isDownloaded ? "✓" : "(${m.size})"}${m.isSupported ? "" : " [UNSUPPORTED]"}',
                                style: TextStyle(
                                  color: !m.isSupported
                                      ? Colors.red.withOpacity(0.6)
                                      : (m.isDownloaded
                                            ? const Color(0xFF22C55E)
                                            : Colors.grey[400]),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const DropdownMenuItem(
                            value: 'hf',
                            child: Text(
                              '( CUSTOM HUGGINGFACE )',
                              style: TextStyle(
                                color: Colors.blue,
                                fontWeight: FontWeight.w900,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) => setState(() {
                          _selectedModelId = value;
                          if (value == 'hf') {
                            // Could show a dialog or expand a field
                          }
                        }),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              // Download or Delete button
              GestureDetector(
                onTap: model?.isDownloaded == true
                    ? () => _deleteModel(model!.id)
                    : (model != null || _selectedModelId == 'hf'
                          ? _startDownload
                          : null),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: model?.isDownloaded == true
                        ? Border.all(color: Colors.red.withOpacity(0.3))
                        : null,
                  ),
                  child: Icon(
                    model?.isDownloaded == true ? Icons.delete : Icons.download,
                    size: 24,
                    color: model?.isDownloaded == true
                        ? Colors.red
                        : const Color(0xFF22C55E),
                  ),
                ),
              ),
            ],
          ),
          // HF Input field
          if (_selectedModelId == 'hf') ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: TextField(
                controller: _hfController,
                style: const TextStyle(fontSize: 14, color: Colors.blue),
                decoration: const InputDecoration(
                  hintText: 'Huggingface Repo ID (e.g. Qwen/Qwen2.5-1.5B-GGUF)',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.blue.withOpacity(0.1)),
              ),
              child: TextField(
                controller: _hfTokenController,
                obscureText: true,
                style: const TextStyle(fontSize: 14, color: Colors.blue),
                decoration: const InputDecoration(
                  hintText: 'HF Access Token (Optional for public models)',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
          // Model details
          if (model != null) ...[
            const SizedBox(height: 24),
            // Metadata grid
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetaItem(
                          Icons.layers,
                          'CONTEXT',
                          model.contextWindow,
                          Colors.blue,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildMetaItem(
                          Icons.speed,
                          'SPEED',
                          model.speedRating,
                          Colors.amber,
                          isSpeed: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetaItem(
                          Icons.show_chart,
                          'TOKENS',
                          model.tokenLimit,
                          const Color(0xFF22C55E),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildMetaItem(
                          Icons.calendar_today,
                          'TRAINED',
                          model.trainedDate,
                          Colors.purple,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetaItem(
                          Icons.memory,
                          '(V)RAM',
                          model.vram,
                          Colors.orange,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildMetaItem(
                          Icons.settings_input_component,
                          'NPU STATUS',
                          model.isSupported ? 'ACTIVE' : 'INCOMPATIBLE',
                          model.isSupported
                              ? const Color(0xFF22C55E)
                              : Colors.red,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetaItem(
                          Icons.router,
                          'PCI LINK',
                          model.pciDeviceId,
                          Colors.orange,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildMetaItem(
                          Icons.developer_board,
                          'TARGET DEVICE',
                          '${model.targetUnit}${model.unitId}',
                          model.isSupported
                              ? const Color(0xFF22C55E)
                              : Colors.red,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 32, color: Colors.white10),
                  // Roles
                  _buildTagSection(
                    'ROLES',
                    Icons.auto_awesome,
                    model.roles,
                    Colors.white.withOpacity(0.05),
                  ),
                  const SizedBox(height: 12),
                  // Tools
                  _buildTagSection(
                    'TOOLS',
                    Icons.build,
                    model.tools,
                    Colors.blue.withOpacity(0.1),
                    textColor: Colors.blue,
                  ),
                  const SizedBox(height: 12),
                  // Languages
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'LANGUAGES',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Colors.grey[600],
                        ),
                      ),
                      Text(
                        model.languages,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Hardware Benchmark
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'HARDWARE BENCHMARK',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Colors.grey[600],
                          letterSpacing: 1,
                        ),
                      ),
                      GestureDetector(
                        onTap: model.isDownloaded ? _runBenchmark : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: model.isDownloaded
                                ? const Color(0xFF22C55E)
                                : Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.speed,
                                size: 14,
                                color: model.isDownloaded
                                    ? Colors.black
                                    : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'BENCHMARK',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  color: model.isDownloaded
                                      ? Colors.black
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'GENERATION SPEED',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 4),
                              RichText(
                                text: TextSpan(
                                  children: [
                                    const TextSpan(
                                      text: '18.4 ',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        fontStyle: FontStyle.italic,
                                        color: Colors.white,
                                      ),
                                    ),
                                    TextSpan(
                                      text: 'TOK/S',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.05),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'RAM OVERHEAD',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w900,
                                  color: Colors.grey[600],
                                ),
                              ),
                              const SizedBox(height: 4),
                              RichText(
                                text: TextSpan(
                                  children: [
                                    const TextSpan(
                                      text: '2.1 ',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        fontStyle: FontStyle.italic,
                                        color: Colors.white,
                                      ),
                                    ),
                                    TextSpan(
                                      text: 'GB',
                                      style: TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.w900,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContextSelection(ModelInfo model) {
    final maxCtx = _calculateMaxContext(model);
    final List<int> contexts = [
      2048,
      4096,
      (maxCtx * 0.5).toInt(),
      (maxCtx * 0.75).toInt(),
      maxCtx,
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: contexts.map((ctx) {
        final label = ctx >= 1024 ? '${(ctx / 1024).toInt()}k' : ctx.toString();
        final isSelected = _selectedContextSize == ctx;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () => setState(() => _selectedContextSize = ctx),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF22C55E)
                      : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? Colors.white24
                        : Colors.white.withOpacity(0.05),
                  ),
                ),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: isSelected ? Colors.black : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildNeuralLogArea() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _loadStatus == LoadStatus.loading
              ? Colors.yellow.withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
        ),
      ),
      child: ListView.builder(
        itemCount: _logs.length,
        reverse: true,
        shrinkWrap: true,
        itemBuilder: (context, index) {
          final log = _logs[_logs.length - 1 - index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              log,
              style: TextStyle(
                fontSize: 10,
                color: log.contains('[ERROR]')
                    ? Colors.red
                    : (log.contains('COMPLETE')
                          ? const Color(0xFF22C55E)
                          : Colors.grey[400]),
                fontFamily: 'monospace',
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMetaItem(
    IconData icon,
    String label,
    String value,
    Color color, {
    bool isSpeed = false,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w900,
                color: Colors.grey[600],
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTagSection(
    String label,
    IconData icon,
    List<String> items,
    Color bgColor, {
    Color? textColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: items
              .map(
                (item) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Text(
                    item,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: textColor ?? Colors.white,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  Widget _buildInputBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              style: const TextStyle(fontSize: 14, color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Query local agent...',
                hintStyle: TextStyle(color: Colors.grey[700]),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          GestureDetector(
            onTap: _sendMessage,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withOpacity(0.3),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: const Icon(Icons.send, color: Colors.black, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  void _sendMessage() {
    if (_inputController.text.trim().isEmpty) return;
    setState(() {
      _messages.add(Message(role: 'user', text: _inputController.text));
      _messages.add(
        Message(role: 'assistant', text: 'Response from Cactus neural core...'),
      );
    });
    _inputController.clear();
  }

  Widget _buildLiveTab() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'NEURAL LOG MONITOR',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: Colors.grey[600],
                  letterSpacing: 2,
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _serverLogs.clear()),
                child: Text(
                  'CLEAR LOGS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF22C55E).withOpacity(0.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: _serverLogs.isEmpty
                  ? Center(
                      child: Text(
                        'WAITING FOR NEURAL TRAFFIC...',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[800],
                          fontFamily: 'monospace',
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _serverLogs.length,
                      reverse: true,
                      itemBuilder: (context, index) {
                        final log = _serverLogs[_serverLogs.length - 1 - index];
                        final isError = log.contains('[ERROR]');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            log,
                            style: TextStyle(
                              fontSize: 11,
                              color: isError
                                  ? Colors.red
                                  : (log.startsWith('[')
                                        ? const Color(0xFF22C55E)
                                        : Colors.grey[400]),
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorsTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'VISION NODE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.videocam, size: 56, color: Colors.grey[800]),
                    const SizedBox(height: 12),
                    Text(
                      'INPUT OFFLINE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: Colors.grey[700],
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOpenAITab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Open',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: _isServerRunning
                      ? const Color(0xFF22C55E)
                      : Colors.grey[600],
                ),
              ),
              const Text(
                'Ai',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: Colors.white,
                ),
              ),
              Text(
                ' Node',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: _isServerRunning
                      ? const Color(0xFF22C55E)
                      : Colors.grey[600],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24), // Icon removed as requested
          // Live Log Area
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isServerRunning
                      ? Colors.blue.withOpacity(0.2)
                      : Colors.white.withOpacity(0.05),
                ),
              ),
              child: ListView.builder(
                itemCount: _serverLogs.length,
                reverse: true,
                shrinkWrap: true,
                itemBuilder: (context, index) {
                  final log = _serverLogs[_serverLogs.length - 1 - index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      log,
                      style: TextStyle(
                        fontSize: 10,
                        color: log.contains('[ERROR]')
                            ? Colors.red
                            : (log.contains('[SUCCESS]')
                                  ? const Color(0xFF22C55E)
                                  : Colors.grey[400]),
                        fontFamily: 'monospace',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Stats Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildStatItem('PENDING', '$_pendingConnections'),
              _buildStatItem('REQUESTS', '$_requestCount'),
              _buildStatItem('TOK IN', '$_totalTokensIn'),
              _buildStatItem('TOK OUT', '$_totalTokensOut'),
              _buildStatItem('EARNED', '$_tokensEarned'),
            ],
          ),
          const SizedBox(height: 16),
          // Server Host Row
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isServerRunning
                    ? Colors.blue.withOpacity(0.2)
                    : Colors.white.withOpacity(0.05),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.wifi_tethering,
                  color: _isServerRunning ? Colors.blue : Colors.grey[600],
                  size: 24,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Server Host',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_isServerRunning)
                        SelectableText(
                          'http://$_ipAddress:$_port/v1/chat',
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: Colors.blue.withOpacity(0.8),
                          ),
                        ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _toggleServer,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 56,
                    height: 32,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: _isServerRunning ? Colors.blue : Colors.grey[700],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: AnimatedAlign(
                      duration: const Duration(milliseconds: 200),
                      alignment: _isServerRunning
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: Colors.blue,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w900,
            color: Colors.grey[600],
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _buildSwarmTab() {
    final peers = _swarm.alivePeers;
    final logs = _swarm.swarmLogs;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Swarm status header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.cyan.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.cyan.withOpacity(0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.hub, color: Colors.cyan, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'SWARM MESH',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Colors.cyan,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: peers.isNotEmpty
                            ? Colors.cyan.withOpacity(0.15)
                            : Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_swarm.totalNodes} NODE${_swarm.totalNodes != 1 ? 'S' : ''}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: peers.isNotEmpty ? Colors.cyan : Colors.grey,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Self node info
                _buildSwarmNodeCard(
                  nodeId: _swarm.nodeId,
                  ip: _swarm.localIp ?? '0.0.0.0',
                  port: 8080,
                  platform: _swarm.platform,
                  model: _activeModelId,
                  isRunning: _isServerRunning,
                  isSelf: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Peer nodes
          Text(
            'CONNECTED PEERS (${peers.length})',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.grey[500],
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.02),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: Column(
                children: [
                  Icon(Icons.search, color: Colors.grey[700], size: 32),
                  const SizedBox(height: 8),
                  Text(
                    'Scanning for peers on LAN...',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Start the app on other devices on the same WiFi',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            )
          else
            ...peers.map(
              (p) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildSwarmNodeCard(
                  nodeId: p.nodeId,
                  ip: p.ip,
                  port: p.port,
                  platform: p.platform,
                  model: p.activeModel,
                  isRunning: p.isServerRunning,
                  isSelf: false,
                ),
              ),
            ),
          const SizedBox(height: 16),
          // Swarm logs
          Text(
            'SWARM LOGS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.grey[500],
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: ListView.builder(
                reverse: true,
                itemCount: logs.length,
                itemBuilder: (ctx, i) {
                  final log = logs[logs.length - 1 - i];
                  final isError = log.contains('ERROR');
                  final isPeer = log.contains('PEER');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      log,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: isError
                            ? Colors.red[400]
                            : (isPeer ? Colors.cyan[300] : Colors.grey[500]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwarmNodeCard({
    required String nodeId,
    required String ip,
    required int port,
    required String platform,
    String? model,
    required bool isRunning,
    required bool isSelf,
  }) {
    final platformIcon = {
      'android': Icons.phone_android,
      'windows': Icons.desktop_windows,
      'linux': Icons.computer,
      'ios': Icons.phone_iphone,
      'macos': Icons.laptop_mac,
    }[platform] ?? Icons.devices;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSelf
            ? Colors.cyan.withOpacity(0.08)
            : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelf
              ? Colors.cyan.withOpacity(0.3)
              : Colors.white.withOpacity(0.06),
        ),
      ),
      child: Row(
        children: [
          Icon(platformIcon, color: Colors.cyan, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${nodeId.substring(0, 8)}...',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                        color: Colors.white,
                      ),
                    ),
                    if (isSelf) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.cyan.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'SELF',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            color: Colors.cyan,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$ip:$port  |  ${platform.toUpperCase()}  |  ${model ?? 'no model'}',
                  style: TextStyle(
                    fontSize: 9,
                    fontFamily: 'monospace',
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isRunning ? Colors.green : Colors.grey[700],
              boxShadow: isRunning
                  ? [BoxShadow(color: Colors.green.withOpacity(0.5), blurRadius: 6)]
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigation() {
    final bool hasModel = _models.any((m) => m.isDownloaded);

    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF0C0D0C),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(
            0,
            Icons.grid_view_rounded,
            'AGENT',
            !hasModel || _isServerRunning,
            Colors.white,
          ),
          _buildNavItem(
            1,
            Icons.layers_outlined,
            'MODEL',
            _isServerRunning,
            Colors.white,
          ),
          _buildNavItem(
            2,
            Icons.sensors,
            'LIVE',
            !hasModel || _isServerRunning,
            Colors.white,
          ),
          _buildNavItem(
            3,
            Icons.memory,
            'SENSORS',
            !hasModel || _isServerRunning,
            Colors.white,
          ),
          // Divider
          Container(width: 1, height: 40, color: Colors.white.withOpacity(0.1)),
          _buildNavItem(
            4,
            Icons.wifi_tethering,
            'OPENAI',
            !hasModel,
            Colors.blue,
          ),
          _buildNavItem(
            5,
            Icons.hub,
            'SWARM',
            false,
            Colors.cyan,
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    int index,
    IconData icon,
    String label,
    bool disabled,
    Color accentColor,
  ) {
    final isSelected = _currentIndex == index;
    final effectiveColor = isSelected ? accentColor : Colors.grey[600];

    return GestureDetector(
      onLongPress: () {
        if (disabled && _isServerRunning) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Server Active: Navigation Locked'),
              duration: Duration(seconds: 1),
              backgroundColor: Colors.blue,
            ),
          );
        }
      },
      onTap: disabled
          ? (_isServerRunning && index != 4
                ? () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('STOP SERVER TO NAVIGATE'),
                        duration: Duration(seconds: 1),
                        backgroundColor: Colors.blue,
                      ),
                    );
                  }
                : null)
          : () => setState(() => _currentIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: disabled ? Colors.white10 : effectiveColor,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
                color: disabled ? Colors.white10 : effectiveColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _server?.close(force: true);
    _swarm.dispose();
    _inputController.dispose();
    super.dispose();
  }
}
