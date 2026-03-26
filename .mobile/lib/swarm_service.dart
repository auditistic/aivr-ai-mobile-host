import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Represents a single node in the AIVR swarm.
class SwarmNode {
  final String nodeId;
  final String ip;
  final int port;
  final String platform; // 'android', 'windows', 'linux', 'ios'
  final String? activeModel;
  final bool isServerRunning;
  DateTime lastSeen;

  SwarmNode({
    required this.nodeId,
    required this.ip,
    required this.port,
    required this.platform,
    this.activeModel,
    this.isServerRunning = false,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  bool get isAlive =>
      DateTime.now().difference(lastSeen).inSeconds < 15;

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'ip': ip,
        'port': port,
        'platform': platform,
        'active_model': activeModel,
        'is_server_running': isServerRunning,
        'last_seen': lastSeen.toIso8601String(),
        'is_alive': isAlive,
      };

  factory SwarmNode.fromJson(Map<String, dynamic> json) => SwarmNode(
        nodeId: json['node_id'] as String,
        ip: json['ip'] as String,
        port: json['port'] as int,
        platform: json['platform'] as String,
        activeModel: json['active_model'] as String?,
        isServerRunning: json['is_server_running'] as bool? ?? false,
        lastSeen: json['last_seen'] != null
            ? DateTime.parse(json['last_seen'] as String)
            : DateTime.now(),
      );
}

/// SwarmService manages decentralized peer discovery and coordination
/// using UDP broadcast on the local network.
///
/// Discovery protocol:
///   - Each node broadcasts a JSON heartbeat on port 41900 every 5 seconds
///   - Heartbeat contains: node_id, ip, port, platform, active_model, server_running
///   - Nodes listen for broadcasts and maintain a peer registry
///   - Peers not seen for 15 seconds are marked as dead
class SwarmService {
  static const int discoveryPort = 41900;
  static const Duration heartbeatInterval = Duration(seconds: 5);
  static const Duration peerTimeout = Duration(seconds: 15);
  static const String _nodeIdKey = 'aivr_swarm_node_id';

  late String _nodeId;
  String? _localIp;
  int _serverPort;
  String? _activeModel;
  bool _isServerRunning = false;

  RawDatagramSocket? _udpSocket;
  Timer? _heartbeatTimer;
  Timer? _cleanupTimer;

  final Map<String, SwarmNode> _peers = {};
  final List<String> _swarmLogs = [];

  // Callbacks
  final ValueNotifier<List<SwarmNode>> peersNotifier =
      ValueNotifier<List<SwarmNode>>([]);
  final ValueNotifier<int> activePeerCount = ValueNotifier<int>(0);

  SwarmService({int serverPort = 8080}) : _serverPort = serverPort;

  String get nodeId => _nodeId;
  String? get localIp => _localIp;
  List<SwarmNode> get peers => _peers.values.toList();
  List<SwarmNode> get alivePeers =>
      _peers.values.where((p) => p.isAlive).toList();
  List<String> get swarmLogs => List.unmodifiable(_swarmLogs);
  int get totalNodes => alivePeers.length + 1; // +1 for self

  String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }

  /// Initialize the swarm service: load or generate node identity.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _nodeId = prefs.getString(_nodeIdKey) ?? const Uuid().v4();
    await prefs.setString(_nodeIdKey, _nodeId);

    _localIp = await _getLocalIp();
    _log('Swarm initialized. Node: ${_nodeId.substring(0, 8)}... on $_localIp');
  }

  /// Start broadcasting presence and listening for peers.
  Future<void> startDiscovery() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.multicastLoopback = false;

      _log('Discovery started on port $discoveryPort');

      // Listen for peer broadcasts
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram != null) {
            _handleIncomingBroadcast(datagram);
          }
        }
      });

      // Start heartbeat
      _sendHeartbeat(); // immediate first beat
      _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
        _sendHeartbeat();
      });

      // Start cleanup of stale peers
      _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        _cleanupStalePeers();
      });
    } catch (e) {
      _log('[ERROR] Discovery failed: $e');
    }
  }

  /// Stop discovery and clean up resources.
  void stopDiscovery() {
    _heartbeatTimer?.cancel();
    _cleanupTimer?.cancel();
    _udpSocket?.close();
    _udpSocket = null;
    _log('Discovery stopped');
  }

  /// Update the state this node advertises to the swarm.
  void updateState({
    String? activeModel,
    bool? isServerRunning,
    int? serverPort,
  }) {
    if (activeModel != null) _activeModel = activeModel;
    if (isServerRunning != null) _isServerRunning = isServerRunning;
    if (serverPort != null) _serverPort = serverPort;
  }

  /// Send a heartbeat broadcast to the LAN.
  void _sendHeartbeat() {
    if (_udpSocket == null) return;

    final payload = jsonEncode({
      'proto': 'aivr-swarm-v1',
      'node_id': _nodeId,
      'ip': _localIp ?? '0.0.0.0',
      'port': _serverPort,
      'platform': platform,
      'active_model': _activeModel,
      'is_server_running': _isServerRunning,
      'timestamp': DateTime.now().toIso8601String(),
    });

    try {
      _udpSocket!.send(
        utf8.encode(payload),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (e) {
      debugPrint('Heartbeat send error: $e');
    }
  }

  /// Handle an incoming UDP broadcast from a peer.
  void _handleIncomingBroadcast(Datagram datagram) {
    try {
      final data = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;

      // Validate protocol
      if (data['proto'] != 'aivr-swarm-v1') return;

      final peerId = data['node_id'] as String;
      // Ignore our own broadcasts
      if (peerId == _nodeId) return;

      final isNew = !_peers.containsKey(peerId);

      _peers[peerId] = SwarmNode(
        nodeId: peerId,
        ip: data['ip'] as String? ?? datagram.address.address,
        port: data['port'] as int? ?? 8080,
        platform: data['platform'] as String? ?? 'unknown',
        activeModel: data['active_model'] as String?,
        isServerRunning: data['is_server_running'] as bool? ?? false,
      );

      if (isNew) {
        _log('[PEER JOINED] ${peerId.substring(0, 8)}... '
            '(${data['platform']}) at ${data['ip']}:${data['port']}');
      }

      _notifyPeersChanged();
    } catch (e) {
      // Ignore malformed packets
    }
  }

  /// Remove peers that haven't sent a heartbeat recently.
  void _cleanupStalePeers() {
    final staleIds = <String>[];
    for (final entry in _peers.entries) {
      if (!entry.value.isAlive) {
        staleIds.add(entry.key);
      }
    }

    for (final id in staleIds) {
      _log('[PEER LEFT] ${id.substring(0, 8)}...');
      _peers.remove(id);
    }

    if (staleIds.isNotEmpty) {
      _notifyPeersChanged();
    }
  }

  void _notifyPeersChanged() {
    peersNotifier.value = peers;
    activePeerCount.value = alivePeers.length;
  }

  /// Forward a chat completion request to a specific peer node.
  Future<Map<String, dynamic>?> forwardRequest(
    SwarmNode peer,
    Map<String, dynamic> requestBody,
  ) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final uri = Uri.parse(
        'http://${peer.ip}:${peer.port}/v1/chat/completions',
      );
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(requestBody));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (response.statusCode == 200) {
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      _log('[FORWARD ERROR] ${peer.nodeId.substring(0, 8)}: $e');
    }
    return null;
  }

  /// Round-robin select an available peer for load balancing.
  SwarmNode? selectPeerForTask() {
    final available =
        alivePeers.where((p) => p.isServerRunning).toList();
    if (available.isEmpty) return null;

    // Simple round-robin based on request count modulo
    available.sort((a, b) => a.nodeId.compareTo(b.nodeId));
    return available[DateTime.now().millisecondsSinceEpoch % available.length];
  }

  /// Get full swarm status for API responses.
  Map<String, dynamic> getSwarmStatus() {
    return {
      'self': {
        'node_id': _nodeId,
        'ip': _localIp,
        'port': _serverPort,
        'platform': platform,
        'active_model': _activeModel,
        'is_server_running': _isServerRunning,
      },
      'peers': alivePeers.map((p) => p.toJson()).toList(),
      'total_nodes': totalNodes,
      'discovery_port': discoveryPort,
      'heartbeat_interval_sec': heartbeatInterval.inSeconds,
    };
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _swarmLogs.add('[$ts] $message');
    if (_swarmLogs.length > 200) _swarmLogs.removeAt(0);
    debugPrint('[SWARM] $message');
  }

  void dispose() {
    stopDiscovery();
    peersNotifier.dispose();
    activePeerCount.dispose();
  }
}
