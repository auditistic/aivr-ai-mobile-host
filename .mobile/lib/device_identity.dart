import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography_flutter/cryptography_flutter.dart';

/// Device identity — ECDSA P-256 keypair for secure farm authentication.
///
/// Per AIVR Device Node API spec:
///   - Generate ECDSA P-256 keypair on first run
///   - Export public key as Base64-encoded SPKI
///   - Sign nonces with SHA-256 for challenge-response auth
///   - Private key NEVER leaves the device
class DeviceIdentity {
  late final Ecdsa _ecdsa;

  EcKeyPair? _keyPair;
  EcPublicKey? _publicKey;

  DeviceIdentity() {
    // Use FlutterCryptography for platform-native ECDSA (Android/iOS)
    // Falls back to pure Dart on desktop
    FlutterCryptography.enable();
    _ecdsa = Ecdsa.p256(Sha256());
  }

  /// Raw public key bytes (uncompressed point, for internal use).
  Future<List<int>> get publicKeyBytes async {
    final pk = await _keyPair!.extractPublicKey();
    return pk.x + pk.y;
  }

  /// Public key as Base64-encoded SPKI format (what the server expects).
  /// SPKI wraps the raw EC point with algorithm identifiers.
  Future<String> get publicKeySpkiBase64 async {
    final pk = await _keyPair!.extractPublicKey();

    // Build SPKI structure for P-256:
    // SEQUENCE {
    //   SEQUENCE { OID ecPublicKey, OID prime256v1 }
    //   BIT STRING { 0x04 || x || y }
    // }
    final xBytes = _padTo32(pk.x);
    final yBytes = _padTo32(pk.y);

    // Uncompressed EC point: 0x04 + 32 bytes X + 32 bytes Y = 65 bytes
    final ecPoint = <int>[0x04, ...xBytes, ...yBytes];

    // ASN.1 DER encoding of SPKI for P-256
    // Algorithm identifier for EC + P-256 is fixed:
    //   SEQUENCE { OID 1.2.840.10045.2.1, OID 1.2.840.10045.3.1.7 }
    final algorithmId = <int>[
      0x30, 0x13, // SEQUENCE, 19 bytes
      0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID ecPublicKey
      0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID prime256v1
    ];

    // BIT STRING wrapping: 0x03, length+1, 0x00 (no unused bits), then ecPoint
    final bitString = <int>[
      0x03, ecPoint.length + 1, 0x00, ...ecPoint,
    ];

    // Outer SEQUENCE
    final innerLength = algorithmId.length + bitString.length;
    final spki = <int>[
      0x30, innerLength, ...algorithmId, ...bitString,
    ];

    return base64Encode(Uint8List.fromList(spki));
  }

  List<int> _padTo32(List<int> bytes) {
    if (bytes.length >= 32) return bytes.sublist(bytes.length - 32);
    return List<int>.filled(32 - bytes.length, 0) + bytes;
  }

  /// Generate a new keypair. Returns the key material for storage.
  Future<KeyMaterial> generateKeyPair() async {
    final keyPair = await _ecdsa.newKeyPair();
    _keyPair = keyPair;
    _publicKey = await keyPair.extractPublicKey();

    // Extract private key data for storage
    final extracted = await keyPair.extract();
    final pk = _publicKey!;

    return KeyMaterial(
      privateKeyD: base64Encode(Uint8List.fromList(extracted.d)),
      publicKeyX: base64Encode(Uint8List.fromList(pk.x)),
      publicKeyY: base64Encode(Uint8List.fromList(pk.y)),
      publicKeySpki: await publicKeySpkiBase64,
    );
  }

  /// Restore keypair from stored material.
  Future<void> restoreKeyPair(KeyMaterial material) async {
    final d = base64Decode(material.privateKeyD);
    final x = base64Decode(material.publicKeyX);
    final y = base64Decode(material.publicKeyY);

    _publicKey = EcPublicKey(
      x: x,
      y: y,
      type: KeyPairType.p256,
    );

    _keyPair = EcKeyPairData(
      d: d,
      x: x,
      y: y,
      type: KeyPairType.p256,
    );
  }

  bool get hasKeyPair => _keyPair != null;

  /// Sign a nonce string with the private key (ECDSA P-256 + SHA-256).
  /// Returns Base64-encoded DER signature.
  Future<String> signNonce(String nonce) async {
    if (_keyPair == null) throw StateError('No keypair loaded');

    final data = utf8.encode(nonce);
    final signature = await _ecdsa.sign(data, keyPair: _keyPair!);
    return base64Encode(Uint8List.fromList(signature.bytes));
  }
}

/// Serializable key material for secure storage.
class KeyMaterial {
  final String privateKeyD; // Base64-encoded private scalar
  final String publicKeyX; // Base64-encoded X coordinate
  final String publicKeyY; // Base64-encoded Y coordinate
  final String publicKeySpki; // Base64-encoded SPKI (for server)

  KeyMaterial({
    required this.privateKeyD,
    required this.publicKeyX,
    required this.publicKeyY,
    required this.publicKeySpki,
  });

  Map<String, String> toJson() => {
        'private_key_d': privateKeyD,
        'public_key_x': publicKeyX,
        'public_key_y': publicKeyY,
        'public_key_spki': publicKeySpki,
      };

  factory KeyMaterial.fromJson(Map<String, dynamic> json) => KeyMaterial(
        privateKeyD: json['private_key_d'] as String,
        publicKeyX: json['public_key_x'] as String,
        publicKeyY: json['public_key_y'] as String,
        publicKeySpki: json['public_key_spki'] as String,
      );
}
