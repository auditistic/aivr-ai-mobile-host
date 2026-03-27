import 'dart:io';
import 'dart:convert';
import 'package:cactus/cactus.dart';
import 'package:uuid/uuid.dart';

import 'node_state.dart';
import 'device_capabilities.dart';
import 'farm_connection.dart';
import 'farm_command_handler.dart';

// ---------------------------------------------------------------------------
// AIVR - Node — Headless CLI mode.
//
// For desktop/server deployments (Windows, macOS, Linux) where no GUI is
// needed. Runs as a background process/service, connects to the AI Farm,
// and serves inference.
//
// Usage:
//   dart run lib/main_headless.dart
//   dart run lib/main_headless.dart --farm-url wss://custom.farm.ai/ws/node
//   dart run lib/main_headless.dart --node-id my-custom-id
//
// Environment variables:
//   AIVR_FARM_URL  — Override farm gateway URL
//   AIVR_NODE_ID   — Override node ID (persistent by default)
// ---------------------------------------------------------------------------

const kDefaultFarmGateway = 'wss://farm.aivr.ai/ws/node';

Future<void> main(List<String> args) async {
  print('');
  print('  ╔══════════════════════════════════════╗');
  print('  ║          AIVR - NODE (Headless)        ║');
  print('  ║     Dedicated AI Inference Worker     ║');
  print('  ╚══════════════════════════════════════╝');
  print('');

  // Parse args
  String? farmUrl;
  String? nodeId;
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--farm-url' && i + 1 < args.length) {
      farmUrl = args[i + 1];
    }
    if (args[i] == '--node-id' && i + 1 < args.length) {
      nodeId = args[i + 1];
    }
  }

  // Environment overrides
  farmUrl ??= Platform.environment['AIVR_FARM_URL'];
  nodeId ??= Platform.environment['AIVR_NODE_ID'];
  farmUrl ??= kDefaultFarmGateway;

  // Persistent node ID
  final nodeIdFile = File('.aivr_node_id');
  if (nodeId == null) {
    if (await nodeIdFile.exists()) {
      nodeId = (await nodeIdFile.readAsString()).trim();
    } else {
      nodeId = const Uuid().v4();
      await nodeIdFile.writeAsString(nodeId);
    }
  }

  print('  Node ID:  $nodeId');
  print('  Farm:     $farmUrl');
  print('  Platform: ${DeviceCapabilities.isDesktop ? "Desktop" : "Mobile"}');
  print('');

  // State
  final state = NodeState();
  state.nodeId = nodeId;
  state.farmGatewayUrl = farmUrl;

  // Device capabilities
  print('  Detecting hardware...');
  state.capabilities = await DeviceCapabilities.gather();
  final caps = state.capabilities!;
  print('  CPU:      ${caps.cpuCores} cores');
  print('  RAM:      ${caps.totalRamMb} MB');
  print('  Storage:  ${caps.availableStorageMb} MB free');
  print('  Compute:  ${caps.computePreference.name.toUpperCase()}'
      '${caps.gpuName != null ? " (${caps.gpuName})" : ""}');
  print('');

  // Cactus LLM
  final cactusLM = CactusLM();

  // Discover models
  try {
    final sdkModels = await cactusLM.getModels().timeout(
      const Duration(seconds: 10),
    );
    final downloaded = sdkModels.where((m) => m.isDownloaded).toList();
    state.capabilities!.downloadedModels = downloaded
        .map((m) => DownloadedModel(id: m.slug, name: m.name, sizeMb: m.sizeMb))
        .toList();
    print('  Models:   ${downloaded.length} downloaded');
    for (final m in downloaded) {
      print('            - ${m.name} (${m.slug})');
    }
  } catch (e) {
    print('  Models:   discovery failed ($e)');
  }
  print('');

  // Command handler
  final handler = FarmCommandHandler(cactusLM: cactusLM, state: state);

  // Farm connection
  final farm = FarmConnection(
    gatewayUrl: farmUrl,
    state: state,
    onCommand: handler.handleCommand,
  );
  handler.attachFarm(farm);

  // Log listener
  state.addListener(() {
    // Print latest log to console
    if (state.logs.isNotEmpty) {
      final latest = state.logs.last;
      stdout.writeln('  $latest');
    }
  });

  // Connect
  print('  Connecting to farm...');
  print('  ──────────────────────────────────────');
  await farm.connect();

  // Keep process alive
  // Handle Ctrl+C gracefully
  ProcessSignal.sigint.watch().listen((_) async {
    print('');
    print('  Shutting down...');
    await farm.disconnect();
    cactusLM.unload();
    print('  Node deregistered. Goodbye.');
    exit(0);
  });

  // Also handle SIGTERM for systemd/Docker
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await farm.disconnect();
      cactusLM.unload();
      exit(0);
    });
  }

  // Block forever (event loop keeps running for WebSocket)
  await Future.delayed(const Duration(days: 365 * 100));
}
