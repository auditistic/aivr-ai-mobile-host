import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Device identity — ECDSA P-256 keypair for secure farm authentication.
///
/// Uses pointycastle (pure Dart, works on all platforms including Android).
///
/// Per AIVR Device Node API spec:
///   - Generate ECDSA P-256 keypair on first run
///   - Export public key as Base64-encoded SPKI
///   - Sign nonces with SHA-256 for challenge-response auth
///   - Private key NEVER leaves the device
class DeviceIdentity {
  ECPrivateKey? _privateKey;
  ECPublicKey? _publicKey;

  static final ECDomainParameters _params = ECCurve_secp256r1();

  bool get hasKeyPair => _privateKey != null && _publicKey != null;

  /// Public key as Base64-encoded SPKI format (what the server expects).
  String get publicKeySpkiBase64 {
    if (_publicKey == null) throw StateError('No keypair loaded');

    final q = _publicKey!.Q!;
    final xBytes = _padTo32(q.x!.toBigInteger()!);
    final yBytes = _padTo32(q.y!.toBigInteger()!);

    // Uncompressed EC point: 0x04 + 32 bytes X + 32 bytes Y
    final ecPoint = <int>[0x04, ...xBytes, ...yBytes];

    // ASN.1 DER SPKI for P-256
    final algorithmId = <int>[
      0x30, 0x13,
      0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID ecPublicKey
      0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID prime256v1
    ];

    final bitString = <int>[0x03, ecPoint.length + 1, 0x00, ...ecPoint];
    final innerLength = algorithmId.length + bitString.length;
    final spki = <int>[0x30, innerLength, ...algorithmId, ...bitString];

    return base64Encode(Uint8List.fromList(spki));
  }

  /// Generate a new keypair. Returns the key material for storage.
  KeyMaterial generateKeyPair() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));

    final keyGen = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(_params),
        secureRandom,
      ));

    final pair = keyGen.generateKeyPair();
    _privateKey = pair.privateKey as ECPrivateKey;
    _publicKey = pair.publicKey as ECPublicKey;

    final d = _privateKey!.d!;
    final q = _publicKey!.Q!;

    return KeyMaterial(
      privateKeyD: base64Encode(Uint8List.fromList(_bigIntToBytes(d))),
      publicKeyX: base64Encode(Uint8List.fromList(_padTo32(q.x!.toBigInteger()!))),
      publicKeyY: base64Encode(Uint8List.fromList(_padTo32(q.y!.toBigInteger()!))),
      publicKeySpki: publicKeySpkiBase64,
    );
  }

  /// Restore keypair from stored material.
  void restoreKeyPair(KeyMaterial material) {
    final d = _bytesToBigInt(base64Decode(material.privateKeyD));
    final x = _bytesToBigInt(base64Decode(material.publicKeyX));
    final y = _bytesToBigInt(base64Decode(material.publicKeyY));

    final q = _params.curve.createPoint(x, y);
    _privateKey = ECPrivateKey(d, _params);
    _publicKey = ECPublicKey(q, _params);
  }

  /// Sign a nonce string with the private key (ECDSA P-256 + SHA-256).
  /// Returns Base64-encoded DER signature.
  String signNonce(String nonce) {
    if (_privateKey == null) throw StateError('No keypair loaded');

    final signer = ECDSASigner(SHA256Digest())
      ..init(true, PrivateKeyParameter<ECPrivateKey>(_privateKey!));

    final data = Uint8List.fromList(utf8.encode(nonce));
    final sig = signer.generateSignature(data) as ECSignature;

    // Encode as DER
    final rBytes = _bigIntToBytes(sig.r);
    final sBytes = _bigIntToBytes(sig.s);

    // DER INTEGER encoding (with leading 0x00 if high bit set)
    final rDer = _derInteger(rBytes);
    final sDer = _derInteger(sBytes);

    final seqLen = rDer.length + sDer.length;
    final der = <int>[0x30, seqLen, ...rDer, ...sDer];

    return base64Encode(Uint8List.fromList(der));
  }

  // --- Helpers ---

  List<int> _padTo32(BigInt value) {
    final bytes = _bigIntToBytes(value);
    if (bytes.length >= 32) return bytes.sublist(bytes.length - 32);
    return List<int>.filled(32 - bytes.length, 0) + bytes;
  }

  List<int> _bigIntToBytes(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length % 2 != 0) hex = '0$hex';
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  BigInt _bytesToBigInt(List<int> bytes) {
    return BigInt.parse(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16,
    );
  }

  List<int> _derInteger(List<int> bytes) {
    // Add leading 0x00 if high bit is set (positive integer)
    final needsPad = bytes.isNotEmpty && bytes[0] >= 0x80;
    final content = needsPad ? [0x00, ...bytes] : bytes;
    return [0x02, content.length, ...content];
  }
}

/// Serializable key material for secure storage.
class KeyMaterial {
  final String privateKeyD;
  final String publicKeyX;
  final String publicKeyY;
  final String publicKeySpki;

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
