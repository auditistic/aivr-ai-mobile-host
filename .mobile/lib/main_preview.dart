import 'dart:async';
import 'package:flutter/material.dart';
import 'screens/status_dashboard.dart';
import 'node_state.dart';
import 'device_capabilities_data.dart';

// ---------------------------------------------------------------------------
// AIVR - Node — Web Preview / Demo Mode
//
// This entry point runs in a browser with simulated farm data so you can
// see the UI without needing a real farm connection or Cactus SDK.
//
// Usage: flutter run -d chrome --target lib/main_preview.dart
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FarmNodePreview());
}

class FarmNodePreview extends StatelessWidget {
  const FarmNodePreview({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIVR - Node — Preview',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        fontFamily: 'Inter',
      ),
      home: const PreviewBootstrap(),
    );
  }
}

class PreviewBootstrap extends StatefulWidget {
  const PreviewBootstrap({super.key});

  @override
  State<PreviewBootstrap> createState() => _PreviewBootstrapState();
}

class _PreviewBootstrapState extends State<PreviewBootstrap> {
  final NodeState _state = NodeState();
  bool _booted = false;
  Timer? _simulator;

  @override
  void initState() {
    super.initState();
    _bootPreview();
  }

  Future<void> _bootPreview() async {
    // Simulate boot sequence
    _state.nodeId = 'a3f8c2d1-7e4b-4a9f-b3c1-demo-preview';
    _state.farmGatewayUrl = 'wss://farm.aivr.ai/ws/node';
    _state.capabilities = DeviceCapabilities(
      cpuCores: 8,
      totalRamMb: 7812,
      availableStorageMb: 28400,
      osVersion: 'Android 14 (API 34)',
      platform: 'android',
      computePreference: ComputePreference.npu,
      gpuName: 'Qualcomm Hexagon NPU',
      downloadedModels: [
        const DownloadedModel(id: 'qwen3-0.6', name: 'Qwen 3 0.6B', sizeMb: 1200),
      ],
    );

    _state.addLog('Gathering device capabilities...');
    await Future.delayed(const Duration(milliseconds: 400));
    _state.addLog('ANDROID: 8 cores, 7812MB RAM, 28400MB storage');
    _state.addLog('Compute: NPU (Qualcomm Hexagon NPU)');

    await Future.delayed(const Duration(milliseconds: 300));
    _state.addLog('Found 1 downloaded model(s)');

    await Future.delayed(const Duration(milliseconds: 200));
    _state.addLog('Wake lock enabled (mobile)');

    await Future.delayed(const Duration(milliseconds: 300));
    _state.connectionState = FarmConnectionState.connecting;
    _state.addLog('Connecting to farm: wss://farm.aivr.ai/ws/node');

    await Future.delayed(const Duration(milliseconds: 800));
    _state.connectionState = FarmConnectionState.connected;
    _state.addLog('Connected to AI Farm');

    await Future.delayed(const Duration(milliseconds: 500));
    _state.addLog('Farm command: load_model');
    _state.addLog('Loading model: qwen3-0.6 (ctx=4096)');

    await Future.delayed(const Duration(milliseconds: 600));
    _state.setModel('qwen3-0.6', 'Qwen 3 0.6B', true);
    _state.addLog('Model loaded: Qwen 3 0.6B');

    setState(() => _booted = true);

    // Simulate ongoing inference activity
    _simulator = Timer.periodic(const Duration(seconds: 3), (_) {
      _simulateInference();
    });
  }

  void _simulateInference() {
    if (!mounted) return;

    final tokIn = 12 + (DateTime.now().millisecond % 30);
    final tokOut = 40 + (DateTime.now().millisecond % 80);
    final speed = 18.0 + (DateTime.now().millisecond % 200) / 10.0;

    _state.totalTokensIn += tokIn;
    _state.totalTokensOut += tokOut;
    _state.requestCount++;
    _state.lastTokenSpeed = speed;

    _state.addLog(
      'Inference: $tokOut tok (${speed.toStringAsFixed(1)} tok/s)',
    );
    // Force notify since we're setting fields directly
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    _state.notifyListeners();
  }

  @override
  void dispose() {
    _simulator?.cancel();
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
      onReconnect: () {
        _state.addLog('Manual reconnect requested (preview mode)');
      },
    );
  }
}
