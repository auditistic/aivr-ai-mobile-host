import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device identity — Ed25519 keypair for secure farm authentication.
///
/// On first run, generates an Ed25519 keypair. The private key is stored
/// locally (SharedPreferences — should be moved to Android Keystore /
/// iOS Keychain for production). The public key and fingerprint are sent
/// to the farm during pairing.
///
/// Flow:
///   1. First run → generate keypair → store
///   2. Show pairing code (fingerprint) to user
///   3. User enters code on farm portal → farm stores public key
///   4. Device signs challenges from auth.aivr.site to prove identity
///   5. Gets back a session JWT → connects to farm WebSocket
class DeviceIdentity {
  static const _keyPrivate = 'device_private_key';
  static const _keyPublic = 'device_public_key';
  static const _keyPaired = 'device_paired';
  static const _keyPairCode = 'device_pair_code';

  final Ed25519 _ed25519 = Ed25519();

  SimpleKeyPair? _keyPair;
  SimplePublicKey? _publicKey;
  bool _isPaired = false;
  String? _pairCode;

  bool get isPaired => _isPaired;
  String? get pairCode => _pairCode;

  /// Public key bytes (raw, 32 bytes).
  Future<Uint8List> get publicKeyBytes async {
    final pk = await _keyPair!.extractPublicKey();
    return Uint8List.fromList(pk.bytes);
  }

  /// Public key as base64 (for API transport).
  Future<String> get publicKeyBase64 async {
    final bytes = await publicKeyBytes;
    return base64Encode(bytes);
  }

  /// Device fingerprint — short human-readable code derived from public key.
  /// Format: XXXX-XXXX-XXXX (12 hex chars from SHA-256 of public key).
  Future<String> get fingerprint async {
    final bytes = await publicKeyBytes;
    final hash = await Sha256().hash(bytes);
    final hex = hash.bytes
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}';
  }

  /// Initialize — load existing keypair or generate new one.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPrivate = prefs.getString(_keyPrivate);
    final storedPublic = prefs.getString(_keyPublic);

    if (storedPrivate != null && storedPublic != null) {
      // Restore existing keypair
      final privateBytes = base64Decode(storedPrivate);
      final publicBytes = base64Decode(storedPublic);

      _publicKey = SimplePublicKey(publicBytes, type: KeyPairType.ed25519);
      _keyPair = SimpleKeyPairData(
        privateBytes,
        publicKey: _publicKey!,
        type: KeyPairType.ed25519,
      );
    } else {
      // Generate new keypair
      final newKeyPair = await _ed25519.newKeyPair();
      final extractedPrivate = await newKeyPair.extractPrivateKeyBytes();
      final extractedPublic = await newKeyPair.extractPublicKey();

      _publicKey = extractedPublic as SimplePublicKey;
      _keyPair = SimpleKeyPairData(
        extractedPrivate,
        publicKey: _publicKey!,
        type: KeyPairType.ed25519,
      );

      // Store
      await prefs.setString(_keyPrivate, base64Encode(extractedPrivate));
      await prefs.setString(_keyPublic, base64Encode(extractedPublic.bytes));
    }

    _isPaired = prefs.getBool(_keyPaired) ?? false;
    _pairCode = prefs.getString(_keyPairCode);

    // Generate pair code if not set
    if (_pairCode == null) {
      _pairCode = await fingerprint;
      await prefs.setString(_keyPairCode, _pairCode!);
    }
  }

  /// Sign a challenge from the auth server to prove device identity.
  /// Returns the signature as base64.
  Future<String> signChallenge(String challenge) async {
    final data = utf8.encode(challenge);
    final signature = await _ed25519.sign(data, keyPair: _keyPair!);
    return base64Encode(signature.bytes);
  }

  /// Mark device as paired (called after successful pairing with farm).
  Future<void> markPaired() async {
    _isPaired = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPaired, true);
  }

  /// Unpair device (factory reset of identity).
  Future<void> unpair() async {
    _isPaired = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPaired, false);
  }

  /// Full reset — delete keypair and pairing state.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPrivate);
    await prefs.remove(_keyPublic);
    await prefs.remove(_keyPaired);
    await prefs.remove(_keyPairCode);
    _keyPair = null;
    _publicKey = null;
    _isPaired = false;
    _pairCode = null;
  }
}
