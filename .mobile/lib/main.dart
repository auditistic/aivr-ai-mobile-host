import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cactus/cactus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'node_state.dart';
import 'device_capabilities.dart';
import 'device_identity.dart';
import 'auth_client.dart';
import 'farm_connection.dart';
import 'farm_command_handler.dart';
import 'screens/status_dashboard.dart';
import 'screens/pairing_screen.dart';

// ---------------------------------------------------------------------------
// AIVR - Node — Dedicated AI inference worker.
//
// Cross-platform: Android, iOS, Windows, macOS, Linux.
//
// Boot flow:
//   1. Generate/load Ed25519 device keypair
//   2. If not paired → show pairing screen (fingerprint code)
//   3. If paired → authenticate via auth.aivr.site (challenge-response)
//   4. Connect WebSocket to farm with JWT Bearer token
//   5. Accept commands, rip tokens, earn money
// ---------------------------------------------------------------------------

const kDefaultFarmGateway = 'wss://farm.aivr.ai/ws/node';
const kDefaultAuthUrl = 'https://auth.aivr.site';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FarmNodeApp());
}

class FarmNodeApp extends StatelessWidget {
  const FarmNodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AIVR - Node',
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

class NodeBootstrap extends StatefulWidget {
  const NodeBootstrap({super.key});

  @override
  State<NodeBootstrap> createState() => _NodeBootstrapState();
}

enum _BootPhase { loading, pairing, authenticating, dashboard }

class _NodeBootstrapState extends State<NodeBootstrap> with WidgetsBindingObserver {
  final NodeState _state = NodeState();
  final CactusLM _cactusLM = CactusLM();
  final DeviceIdentity _identity = DeviceIdentity();
  late final AuthClient _auth;
  late final FarmCommandHandler _commandHandler;
  late final FarmConnection _farm;

  _BootPhase _phase = _BootPhase.loading;

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

    // 2. URLs
    final farmUrl = prefs.getString('farm_url') ?? kDefaultFarmGateway;
    final authUrl = prefs.getString('auth_url') ?? kDefaultAuthUrl;
    _state.farmGatewayUrl = farmUrl;

    // 3. Initialize device identity (Ed25519 keypair)
    _state.addLog('Initializing device identity...');
    await _identity.initialize();
    final fp = await _identity.fingerprint;
    _state.addLog('Device fingerprint: $fp');

    // 4. Auth client
    _auth = AuthClient(
      authBaseUrl: authUrl,
      identity: _identity,
      nodeId: nodeId,
    );

    // 5. Gather device capabilities
    _state.addLog('Detecting hardware...');
    _state.capabilities = await DeviceDetector.gather();
    final caps = _state.capabilities!;
    _state.addLog(
      '${caps.platform.toUpperCase()}: ${caps.cpuCores} cores, '
      '${caps.totalRamMb}MB RAM',
    );

    // 6. Discover models
    try {
      final sdkModels = await _cactusLM.getModels().timeout(
        const Duration(seconds: 10),
      );
      final downloaded = sdkModels.where((m) => m.isDownloaded).toList();
      _state.capabilities!.downloadedModels = downloaded
          .map((m) => DownloadedModel(id: m.slug, name: m.name, sizeMb: m.sizeMb))
          .toList();
      _state.addLog('Found ${downloaded.length} model(s)');
    } catch (e) {
      _state.addLog('Model discovery: $e');
    }

    // 7. Wire up command handler + farm connection
    _commandHandler = FarmCommandHandler(cactusLM: _cactusLM, state: _state);
    _farm = FarmConnection(
      gatewayUrl: farmUrl,
      state: _state,
      onCommand: _commandHandler.handleCommand,
    );
    _commandHandler.attachFarm(_farm);

    // 8. Wake lock (mobile only)
    if (DeviceDetector.isMobile) {
      await WakelockPlus.enable();
      _state.addLog('Wake lock enabled');
    }

    // 9. Check pairing state
    if (!_identity.isPaired) {
      // First run — register with auth server and show pairing screen
      _state.addLog('Device not paired — starting pairing flow');
      try {
        await _auth.registerForPairing();
      } catch (e) {
        _state.addLog('Pairing registration: $e');
      }
      setState(() => _phase = _BootPhase.pairing);
    } else {
      // Already paired — authenticate and connect
      await _authenticateAndConnect();
    }
  }

  Future<void> _authenticateAndConnect() async {
    setState(() => _phase = _BootPhase.authenticating);
    _state.addLog('Authenticating with farm...');

    try {
      final result = await _auth.authenticate();
      if (result.success) {
        _state.addLog('Authentication successful');
        _farm.authToken = _auth.accessToken;
        await _farm.connect();
        setState(() => _phase = _BootPhase.dashboard);
      } else {
        _state.addLog('Auth failed: ${result.error}');
        // Fall through to dashboard anyway — connection will retry
        _farm.authToken = null;
        await _farm.connect();
        setState(() => _phase = _BootPhase.dashboard);
      }
    } catch (e) {
      _state.addLog('Auth error: $e — connecting without token');
      await _farm.connect();
      setState(() => _phase = _BootPhase.dashboard);
    }
  }

  Future<String> _checkPairingStatus() async {
    try {
      final result = await _auth.checkPairingStatus();
      return result.status;
    } catch (e) {
      return 'pending';
    }
  }

  void _onPaired() async {
    await _identity.markPaired();
    _state.addLog('Device paired successfully');
    await _authenticateAndConnect();
  }

  void _reconnect() {
    _state.addLog('Manual reconnect');
    // Refresh auth token if needed
    if (_auth.needsRefresh) {
      _auth.refreshAccessToken().then((result) {
        if (result.success) _farm.authToken = _auth.accessToken;
        _farm.disconnect().then((_) => _farm.connect());
      });
    } else {
      _farm.disconnect().then((_) => _farm.connect());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed &&
        _phase == _BootPhase.dashboard &&
        _state.connectionState != FarmConnectionState.connected) {
      _state.addLog('App resumed — reconnecting');
      _reconnect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _farm.dispose();
    _cactusLM.unload();
    if (DeviceDetector.isMobile) WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _BootPhase.loading:
      case _BootPhase.authenticating:
        return Scaffold(
          backgroundColor: const Color(0xFF0A0A0A),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Color(0xFF22C55E)),
                const SizedBox(height: 24),
                Text(
                  _phase == _BootPhase.authenticating
                      ? 'AUTHENTICATING...'
                      : 'INITIALIZING NODE...',
                  style: const TextStyle(
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

      case _BootPhase.pairing:
        return FutureBuilder<String>(
          future: _identity.fingerprint,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Scaffold(
                backgroundColor: Color(0xFF0A0A0A),
                body: Center(child: CircularProgressIndicator(color: Color(0xFF22C55E))),
              );
            }
            return PairingScreen(
              fingerprint: snap.data!,
              nodeId: _state.nodeId,
              onCheckStatus: _checkPairingStatus,
              onPaired: _onPaired,
            );
          },
        );

      case _BootPhase.dashboard:
        return StatusDashboard(
          state: _state,
          onReconnect: _reconnect,
        );
    }
  }
}
