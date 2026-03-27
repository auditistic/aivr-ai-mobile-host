import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// First-run pairing screen.
///
/// User goes to auth.aivr.site/profile → Devices tab to get a 6-digit
/// pairing code, then enters it here. The app sends the code + public key
/// to the server and receives credentials.
class PairingScreen extends StatefulWidget {
  final Future<PairingResult> Function(String code) onSubmitCode;

  const PairingScreen({
    super.key,
    required this.onSubmitCode,
  });

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class PairingResult {
  final bool success;
  final String? error;
  PairingResult({required this.success, this.error});
}

class _PairingScreenState extends State<PairingScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.length != 6 || int.tryParse(code) == null) {
      setState(() => _error = 'Enter a valid 6-digit code');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await widget.onSubmitCode(code);

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _submitting = false;
        _error = result.error ?? 'Pairing failed';
      });
    }
    // On success, parent navigates away — no setState needed
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
                'Go to auth.aivr.site → Profile → Devices\nand enter the 6-digit pairing code below.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[500],
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),
              // 6-digit code input
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _error != null
                        ? Colors.red.withOpacity(0.5)
                        : const Color(0xFF22C55E).withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  enabled: !_submitting,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    color: Color(0xFF22C55E),
                    letterSpacing: 12,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: '000000',
                    hintStyle: TextStyle(
                      color: Colors.white10,
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      fontFamily: 'monospace',
                      letterSpacing: 12,
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 16),
              // Error message
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.red,
                  ),
                ),
              const SizedBox(height: 24),
              // Submit button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    disabledBackgroundColor: const Color(0xFF22C55E).withOpacity(0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text(
                          'PAIR DEVICE',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                            letterSpacing: 1,
                          ),
                        ),
                ),
              ),
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}
