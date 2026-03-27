import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// First-run pairing screen.
///
/// Shows the device fingerprint code (XXXX-XXXX-XXXX) that the user
/// enters on the farm web portal to approve this node. Polls for
/// approval status automatically.
class PairingScreen extends StatefulWidget {
  final String fingerprint;
  final String nodeId;
  final Future<String> Function() onCheckStatus; // Returns: 'pending', 'approved', 'rejected'
  final VoidCallback onPaired;

  const PairingScreen({
    super.key,
    required this.fingerprint,
    required this.nodeId,
    required this.onCheckStatus,
    required this.onPaired,
  });

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  Timer? _pollTimer;
  String _status = 'pending';
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    // Poll every 3 seconds for approval
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkStatus());
  }

  Future<void> _checkStatus() async {
    try {
      final status = await widget.onCheckStatus();
      if (!mounted) return;
      setState(() => _status = status);
      if (status == 'approved') {
        _pollTimer?.cancel();
        await Future.delayed(const Duration(milliseconds: 500));
        widget.onPaired();
      }
    } catch (_) {
      // Keep polling silently
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Icon
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: const Color(0xFF22C55E).withOpacity(0.3),
                  ),
                ),
                child: const Icon(
                  Icons.link,
                  size: 40,
                  color: Color(0xFF22C55E),
                ),
              ),
              const SizedBox(height: 32),
              // Title
              const Text(
                'PAIR THIS DEVICE',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter this code on your AIVR Farm portal\nto connect this device to your account.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              // Fingerprint code
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.fingerprint));
                  setState(() => _copied = true);
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted) setState(() => _copied = false);
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF22C55E).withOpacity(0.3),
                      width: 2,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.fingerprint,
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'monospace',
                          color: Color(0xFF22C55E),
                          letterSpacing: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _copied ? Icons.check : Icons.copy,
                            size: 14,
                            color: _copied ? const Color(0xFF22C55E) : Colors.grey[600],
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _copied ? 'COPIED' : 'TAP TO COPY',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: _copied ? const Color(0xFF22C55E) : Colors.grey[600],
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Status indicator
              _buildStatusIndicator(),
              const SizedBox(height: 16),
              // Node ID (small)
              Text(
                'Node: ${widget.nodeId.substring(0, 8)}...',
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Colors.grey[700],
                ),
              ),
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    if (_status == 'approved') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 20),
          const SizedBox(width: 8),
          const Text(
            'PAIRED SUCCESSFULLY',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: Color(0xFF22C55E),
              letterSpacing: 1,
            ),
          ),
        ],
      );
    }

    if (_status == 'rejected') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cancel, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          const Text(
            'PAIRING REJECTED',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: Colors.red,
              letterSpacing: 1,
            ),
          ),
        ],
      );
    }

    // Pending — show spinner
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.amber,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'WAITING FOR APPROVAL...',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Colors.amber.withOpacity(0.8),
            letterSpacing: 1,
          ),
        ),
      ],
    );
  }
}
