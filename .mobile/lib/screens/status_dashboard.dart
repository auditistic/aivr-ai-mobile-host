import 'dart:async';
import 'package:flutter/material.dart';
import '../node_state.dart';

/// Read-only status dashboard for the AI Farm worker node.
/// No interactive elements except a manual reconnect button.
class StatusDashboard extends StatefulWidget {
  final NodeState state;
  final VoidCallback? onReconnect;

  const StatusDashboard({
    super.key,
    required this.state,
    this.onReconnect,
  });

  @override
  State<StatusDashboard> createState() => _StatusDashboardState();
}

class _StatusDashboardState extends State<StatusDashboard> {
  Timer? _uptimeTimer;
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Tick every second to update uptime display
    _uptimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uptimeTimer?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => _buildContent(),
    );
  }

  Widget _buildContent() {
    final s = widget.state;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(s),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _buildConnectionCard(s),
                    const SizedBox(height: 12),
                    _buildModelCard(s),
                    const SizedBox(height: 12),
                    _buildTokenEconomyCard(s),
                    const SizedBox(height: 12),
                    _buildStatsGrid(s),
                    const SizedBox(height: 12),
                    _buildLogArea(s),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Header ---
  Widget _buildHeader(NodeState s) {
    final connected = s.connectionState == FarmConnectionState.connected;
    final connecting = s.connectionState == FarmConnectionState.connecting ||
        s.connectionState == FarmConnectionState.reconnecting;

    Color statusColor = connected
        ? const Color(0xFF22C55E)
        : (connecting ? Colors.amber : Colors.red);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.05),
        border: Border(
          bottom: BorderSide(color: statusColor.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(color: statusColor.withOpacity(0.4), blurRadius: 12),
              ],
            ),
            child: const Icon(Icons.memory, color: Colors.black, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AIVR FARM NODE',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    fontStyle: FontStyle.italic,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  connected
                      ? 'CONNECTED TO FARM'
                      : (connecting ? 'CONNECTING...' : 'DISCONNECTED'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          // Status dot
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: statusColor.withOpacity(0.6), blurRadius: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Connection Card ---
  Widget _buildConnectionCard(NodeState s) {
    final caps = s.capabilities;
    return _card(
      children: [
        _labelRow('FARM CONNECTION', Icons.cloud_outlined),
        const SizedBox(height: 12),
        _infoRow('NODE ID', s.nodeId.length > 12
            ? '${s.nodeId.substring(0, 12)}...'
            : s.nodeId),
        _infoRow('PLATFORM', caps?.platform.toUpperCase() ?? 'UNKNOWN'),
        _infoRow('UPTIME', _formatUptime(s.uptimeSeconds)),
        if (caps?.gpuName != null)
          _infoRow('COMPUTE', caps!.gpuName!),
        if (caps?.gpuName == null && caps != null)
          _infoRow('COMPUTE', caps.computePreference.name.toUpperCase()),
        if (caps != null)
          _infoRow('HARDWARE', '${caps.cpuCores} cores / ${caps.totalRamMb}MB RAM'),
        if (s.farmGatewayUrl != null)
          _infoRow('GATEWAY', s.farmGatewayUrl!.replaceAll('wss://', '')),
        if (s.connectionState != FarmConnectionState.connected)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: widget.onReconnect,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('RECONNECT'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.amber,
                  side: BorderSide(color: Colors.amber.withOpacity(0.3)),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // --- Model Card ---
  Widget _buildModelCard(NodeState s) {
    final hasModel = s.isModelLoaded && s.currentModelName != null;
    final downloading = s.downloadProgress != null;

    return _card(
      children: [
        _labelRow('ACTIVE MODEL', Icons.layers_outlined),
        const SizedBox(height: 12),
        if (hasModel) ...[
          Text(
            s.currentModelName!,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: Color(0xFF22C55E),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ID: ${s.currentModelId}',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.grey[500],
            ),
          ),
        ] else if (downloading) ...[
          Text(
            'Downloading: ${s.downloadingModelId ?? "..."}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.amber,
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: s.downloadProgress,
              backgroundColor: Colors.white.withOpacity(0.05),
              valueColor: const AlwaysStoppedAnimation(Colors.amber),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${((s.downloadProgress ?? 0) * 100).toInt()}%',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: Colors.amber.withOpacity(0.8),
            ),
          ),
        ] else ...[
          Text(
            'AWAITING FARM INSTRUCTION',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.grey[600],
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'The farm will assign a model to this node',
            style: TextStyle(fontSize: 11, color: Colors.grey[700]),
          ),
        ],
      ],
    );
  }

  // --- Token Economy Card ---
  Widget _buildTokenEconomyCard(NodeState s) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF22C55E).withOpacity(0.08),
            const Color(0xFF22C55E).withOpacity(0.02),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF22C55E).withOpacity(0.15)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.toll, size: 16, color: const Color(0xFF22C55E).withOpacity(0.6)),
              const SizedBox(width: 8),
              Text(
                'TOKEN EARNINGS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFF22C55E).withOpacity(0.6),
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTokenCount(s.tokensEarned),
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF22C55E),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'TOKENS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF22C55E).withOpacity(0.5),
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Earn tokens by contributing compute. Spend on your own AI or trade on the exchange.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              color: Colors.grey[600],
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // --- Stats Grid ---
  Widget _buildStatsGrid(NodeState s) {
    return Row(
      children: [
        Expanded(child: _statTile('TOKENS IN', _formatTokenCount(s.totalTokensIn), Colors.blue)),
        const SizedBox(width: 8),
        Expanded(child: _statTile('TOKENS OUT', _formatTokenCount(s.totalTokensOut), Colors.purple)),
        const SizedBox(width: 8),
        Expanded(child: _statTile('REQUESTS', '${s.requestCount}', Colors.amber)),
        const SizedBox(width: 8),
        Expanded(child: _statTile('SPEED', '${s.lastTokenSpeed.toStringAsFixed(1)} t/s', const Color(0xFF22C55E))),
      ],
    );
  }

  Widget _statTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.1)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 7,
              fontWeight: FontWeight.w900,
              color: Colors.grey[600],
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  // --- Log Area ---
  Widget _buildLogArea(NodeState s) {
    // Auto-scroll to bottom when logs update
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });

    return Container(
      height: 200,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 12, color: Colors.grey[600]),
              const SizedBox(width: 8),
              Text(
                'NODE LOG',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  color: Colors.grey[600],
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const Divider(color: Colors.white10, height: 16),
          Expanded(
            child: s.logs.isEmpty
                ? Center(
                    child: Text(
                      'Waiting for activity...',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey[800],
                        fontFamily: 'monospace',
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _logScroll,
                    itemCount: s.logs.length,
                    itemBuilder: (context, index) {
                      final log = s.logs[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          log,
                          style: TextStyle(
                            fontSize: 9,
                            fontFamily: 'monospace',
                            color: log.contains('error') || log.contains('Error')
                                ? Colors.red[400]
                                : (log.contains('Connected') || log.contains('complete') || log.contains('loaded')
                                    ? const Color(0xFF22C55E)
                                    : Colors.grey[500]),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // --- Helpers ---

  Widget _card({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _labelRow(String label, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w900,
            color: Colors.grey[600],
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.grey[600],
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  String _formatUptime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatTokenCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }
}
