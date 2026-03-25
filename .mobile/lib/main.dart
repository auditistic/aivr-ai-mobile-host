import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cactus/cactus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'node_state.dart';
import 'device_capabilities.dart';
import 'farm_connection.dart';
import 'farm_command_handler.dart';
import 'screens/status_dashboard.dart';

// ---------------------------------------------------------------------------
// AIVR Farm Node — Dedicated AI inference worker.
//
// Cross-platform: Android, iOS, Windows, macOS, Linux.
//
// This app does ONE thing: connect to the AI Farm via Cloudflare gateway,
// accept commands (download model, load, inference), rip tokens, and
// report earnings. No local chat, no model picker, no user options.
//
// Mobile: phone sits on a charger, wake-locked, earning tokens 24/7.
// Desktop: runs as a background app/service, leveraging NPU/GPU.
//
// Token economy: users earn tokens by contributing device compute.
// Tokens can be spent on their own AI usage or traded on the exchange.
// ---------------------------------------------------------------------------

/// Default farm gateway — override via SharedPreferences 'farm_url'.
const kDefaultFarmGateway = 'wss://farm.aivr.ai/ws/node';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FarmNodeApp());
}

class FarmNodeApp extends StatelessWidget {
  const FarmNodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIVR Farm Node',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        fontFamily: 'Inter',
      ),
      home: const NodeBootstrap(),
    );
  }
}

/// Bootstrap: initializes all services then shows the status dashboard.
class NodeBootstrap extends StatefulWidget {
  const NodeBootstrap({super.key});

  @override
  State<NodeBootstrap> createState() => _NodeBootstrapState();
}

class _NodeBootstrapState extends State<NodeBootstrap> with WidgetsBindingObserver {
  final NodeState _state = NodeState();
  final CactusLM _cactusLM = CactusLM();
  late final FarmCommandHandler _commandHandler;
  late final FarmConnection _farm;
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    // 1. Load or generate persistent node ID
    final prefs = await SharedPreferences.getInstance();
    String? nodeId = prefs.getString('node_id');
    if (nodeId == null) {
      nodeId = const Uuid().v4();
      await prefs.setString('node_id', nodeId);
    }
    _state.nodeId = nodeId;

    // 2. Farm gateway URL (configurable, defaults to production)
    final farmUrl = prefs.getString('farm_url') ?? kDefaultFarmGateway;
    _state.farmGatewayUrl = farmUrl;

    // 3. Gather device capabilities (cross-platform)
    _state.addLog('Gathering device capabilities...');
    _state.capabilities = await DeviceCapabilities.gather();
    final caps = _state.capabilities!;
    _state.addLog(
      '${caps.platform.toUpperCase()}: ${caps.cpuCores} cores, '
      '${caps.totalRamMb}MB RAM, ${caps.availableStorageMb}MB storage',
    );
    _state.addLog(
      'Compute: ${caps.computePreference.name.toUpperCase()}'
      '${caps.gpuName != null ? " (${caps.gpuName})" : ""}',
    );

    // 4. Discover downloaded models from Cactus SDK
    try {
      final sdkModels = await _cactusLM.getModels().timeout(
        const Duration(seconds: 10),
      );
      final downloaded = sdkModels.where((m) => m.isDownloaded).toList();
      _state.capabilities!.downloadedModels = downloaded
          .map((m) => DownloadedModel(
                id: m.slug,
                name: m.name,
                sizeMb: m.sizeMb,
              ))
          .toList();
      _state.addLog('Found ${downloaded.length} downloaded model(s)');
    } catch (e) {
      _state.addLog('Model discovery: $e');
    }

    // 5. Wire up command handler
    _commandHandler = FarmCommandHandler(
      cactusLM: _cactusLM,
      state: _state,
    );

    // 6. Create farm connection
    _farm = FarmConnection(
      gatewayUrl: farmUrl,
      state: _state,
      onCommand: _commandHandler.handleCommand,
    );
    _commandHandler.attachFarm(_farm);

    // 7. Platform-specific setup
    if (DeviceCapabilities.isMobile) {
      // Mobile: keep device awake to serve inference 24/7
      await WakelockPlus.enable();
      _state.addLog('Wake lock enabled (mobile)');
    } else {
      _state.addLog('Desktop mode — no wake lock needed');
    }

    // 8. Auto-connect to farm
    setState(() => _booted = true);
    _farm.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed) {
      // Reconnect if we lost connection while backgrounded
      if (_state.connectionState != FarmConnectionState.connected) {
        _state.addLog('App resumed — reconnecting...');
        _farm.connect();
      }
    }
  }

  void _reconnect() {
    _state.addLog('Manual reconnect requested');
    _farm.disconnect().then((_) => _farm.connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _farm.dispose();
    _cactusLM.unload();
    if (DeviceCapabilities.isMobile) {
      WakelockPlus.disable();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0A0A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF22C55E)),
              SizedBox(height: 24),
              Text(
                'INITIALIZING NODE...',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: Colors.white54,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return StatusDashboard(
      state: _state,
      onReconnect: _reconnect,
    );
  }
}
