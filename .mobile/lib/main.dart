import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cactus/cactus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'node_state.dart';
import 'device_capabilities.dart';
import 'device_identity.dart';
import 'credential_store.dart';
import 'auth_client.dart';
import 'farm_connection.dart';
import 'farm_command_handler.dart';
import 'screens/status_dashboard.dart';
import 'screens/pairing_screen.dart';

// ---------------------------------------------------------------------------
// AIVR - Node — Dedicated AI inference worker.
//
// First-run flow (per DEVICE-NODE-API.md):
//   1. Generate ECDSA P-256 keypair
//   2. User enters 6-digit pairing code from auth.aivr.site/profile
//   3. POST /api/auth/device/pair → receive node_id, JWT, CF creds, farm URL
//   4. Connect WebSocket to farm with Bearer token + CF headers
//   5. Accept commands, rip tokens, earn money
//
// Reconnect flow:
//   - JWT expired → POST /api/device/refresh (rotating refresh token)
//   - Refresh failed → POST /api/device/challenge + /token (sign nonce)
//   - CF 403 → re-pair required
// ---------------------------------------------------------------------------

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

enum _BootPhase { loading, pairing, connecting, dashboard }

class _NodeBootstrapState extends State<NodeBootstrap> with WidgetsBindingObserver {
  final NodeState _state = NodeState();
  final CactusLM _cactusLM = CactusLM();
  final DeviceIdentity _identity = DeviceIdentity();
  final CredentialStore _creds = CredentialStore();
  late final AuthClient _auth;
  late final FarmCommandHandler _commandHandler;
  FarmConnection? _farm;
  Timer? _heartbeatTimer;

  _BootPhase _phase = _BootPhase.loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    // 1. Load stored credentials
    await _creds.load();
    debugPrint('[BOOT] isPaired=${_creds.isPaired} hasCredentials=${_creds.hasCredentials} nodeId=${_creds.nodeId} farmEndpoint=${_creds.farmEndpoint}');

    // 2. Auth client
    _auth = AuthClient(
      authBaseUrl: kDefaultAuthUrl,
      identity: _identity,
      credentials: _creds,
    );

    // 3. Initialize or restore keypair
    if (_creds.keyMaterial != null) {
      _identity.restoreKeyPair(_creds.keyMaterial!);
      _state.addLog('Keypair restored');
    } else {
      _state.addLog('Generating ECDSA P-256 keypair...');
      final km = _identity.generateKeyPair();
      await _creds.saveKeyMaterial(km);
      _state.addLog('Keypair generated');
    }

    // 4. Detect hardware
    _state.addLog('Detecting hardware...');
    _state.capabilities = await DeviceDetector.gather();
    final caps = _state.capabilities!;
    _state.addLog(
      '${caps.platform.toUpperCase()}: ${caps.cpuCores} cores, '
      '${caps.totalRamMb}MB RAM',
    );

    // 5. Discover models
    try {
      final sdkModels = await _cactusLM.getModels().timeout(const Duration(seconds: 10));
      final downloaded = sdkModels.where((m) => m.isDownloaded).toList();
      _state.capabilities!.downloadedModels = downloaded
          .map((m) => DownloadedModel(id: m.slug, name: m.name, sizeMb: m.sizeMb))
          .toList();
      _state.addLog('Found ${downloaded.length} model(s)');
    } catch (e) {
      _state.addLog('Model discovery: $e');
    }

    // 6. Wire up command handler
    _commandHandler = FarmCommandHandler(cactusLM: _cactusLM, state: _state);

    // 7. Wake lock (mobile only)
    if (DeviceDetector.isMobile) {
      await WakelockPlus.enable();
      _state.addLog('Wake lock enabled');
    }

    // 8. Check if already paired
    debugPrint('[BOOT] Decision: isPaired=${_creds.isPaired} hasCredentials=${_creds.hasCredentials} cfClientId=${_creds.cfClientId != null} accessToken=${_creds.accessToken != null}');
    if (_creds.isPaired && _creds.hasCredentials) {
      _state.nodeId = _creds.nodeId ?? '';
      _state.farmGatewayUrl = _creds.farmEndpoint;
      _state.addLog('Device paired as ${_creds.nodeId}');
      await _connectToFarm();
    } else {
      setState(() => _phase = _BootPhase.pairing);
    }
  }

  // -----------------------------------------------------------------------
  // Pairing
  // -----------------------------------------------------------------------

  Future<PairingResult> _handlePairingCode(String code) async {
    _state.addLog('Pairing with code: $code');

    try {
      final result = await _auth.pair(code);

      if (result.isApproved) {
        _state.nodeId = _creds.nodeId ?? '';
        _state.farmGatewayUrl = _creds.farmEndpoint;
        _state.addLog('Paired! Node: ${_creds.nodeId}');
        _state.addLog('Farm: ${_creds.farmName} (${_creds.farmEndpoint})');

        // Transition to connecting — skip token refresh, we just got fresh creds
        await _connectToFarm(freshPair: true);
        return PairingResult(success: true);
      }

      return PairingResult(success: false, error: result.error ?? 'Pairing failed');
    } catch (e) {
      _state.addLog('Pairing error: $e');
      return PairingResult(success: false, error: 'Connection error: $e');
    }
  }

  // -----------------------------------------------------------------------
  // Farm connection
  // -----------------------------------------------------------------------

  Future<void> _connectToFarm({bool freshPair = false}) async {
    setState(() => _phase = _BootPhase.connecting);
    _state.addLog('Connecting to farm...');

    // Only authenticate if reconnecting (not on fresh pair — token is valid)
    if (!freshPair) {
      debugPrint('[BOOT] Running auth priority chain...');
      final authResult = await _auth.ensureAuthenticated();
      if (authResult.requiresRepair) {
        _state.addLog('Auth failed — re-pairing required');
        await _creds.clear();
        setState(() => _phase = _BootPhase.pairing);
        return;
      }
      if (!authResult.success) {
        _state.addLog('Auth failed: ${authResult.error} — trying anyway');
      }
    }

    // Create farm connection with token + CF headers
    final farmUrl = _creds.farmEndpoint ?? 'wss://farm.aivr.site/ws';

    _farm = FarmConnection(
      gatewayUrl: farmUrl,
      state: _state,
      onCommand: _commandHandler.handleCommand,
      authToken: _creds.accessToken,
    );
    _commandHandler.attachFarm(_farm!);

    await _farm!.connect();

    // Start auth server heartbeat (30-60s per spec)
    _startHeartbeat();

    setState(() => _phase = _BootPhase.dashboard);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      // Send heartbeat to auth server
      await _auth.sendHeartbeat(
        gpuModel: _state.capabilities?.gpuName,
        uptimeSeconds: _state.uptimeSeconds,
      );

      // Send telemetry if we have data
      if (_state.requestCount > 0) {
        await _auth.sendTelemetry(
          tokensProcessed: _state.totalTokens,
          tasksCompleted: _state.requestCount,
        );
      }

      // Refresh token if needed (JWT expires in 1 hour)
      // Refresh proactively at 50 minutes to avoid gaps
      // We check every heartbeat cycle
    });
  }

  void _reconnect() async {
    _state.addLog('Reconnecting...');

    // Try refresh token first
    final result = await _auth.refreshAccessToken();
    if (result.requiresRepair) {
      _state.addLog('Credentials revoked — re-pairing');
      _heartbeatTimer?.cancel();
      _farm?.dispose();
      await _creds.clear();
      setState(() => _phase = _BootPhase.pairing);
      return;
    }

    // Update farm connection token
    if (result.success) {
      _farm?.authToken = _creds.accessToken;
    }

    await _farm?.disconnect();
    await _farm?.connect();
  }

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed &&
        _phase == _BootPhase.dashboard &&
        _state.connectionState != FarmConnectionState.connected) {
      _reconnect();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _farm?.dispose();
    _cactusLM.unload();
    if (DeviceDetector.isMobile) WakelockPlus.disable();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // UI
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _BootPhase.loading:
      case _BootPhase.connecting:
        return Scaffold(
          backgroundColor: const Color(0xFF0A0A0A),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Color(0xFF22C55E)),
                const SizedBox(height: 24),
                Text(
                  _phase == _BootPhase.connecting
                      ? 'CONNECTING TO FARM...'
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
        return PairingScreen(onSubmitCode: _handlePairingCode);

      case _BootPhase.dashboard:
        return StatusDashboard(
          state: _state,
          onReconnect: _reconnect,
        );
    }
  }
}
