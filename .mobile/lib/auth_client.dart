import 'dart:convert';
import 'package:http/http.dart' as http;
import 'device_identity.dart';

/// OAuth client for auth.aivr.site — challenge-response using Ed25519 device key.
///
/// Flow:
///   1. POST /api/device/pair   — register public key, get pairing status
///   2. POST /api/device/challenge — get a nonce to sign
///   3. POST /api/device/token   — submit signed nonce, get JWT session token
///   4. Use JWT as Bearer token on WebSocket to farm
///
/// The JWT is short-lived. Refresh before expiry.
class AuthClient {
  final String authBaseUrl; // e.g. https://auth.aivr.site
  final DeviceIdentity identity;
  final String nodeId;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _tokenExpiry;

  AuthClient({
    required this.authBaseUrl,
    required this.identity,
    required this.nodeId,
  });

  /// Current access token (JWT). Null if not authenticated.
  String? get accessToken => _accessToken;
  bool get isAuthenticated =>
      _accessToken != null &&
      _tokenExpiry != null &&
      DateTime.now().isBefore(_tokenExpiry!);

  /// Headers used by the AIVR - Node app.
  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'AIVR-Node/2.1.0',
      };

  // -----------------------------------------------------------------------
  // Step 1: Register device for pairing
  // -----------------------------------------------------------------------

  /// Submit public key to auth server. Returns pairing status.
  /// Call this on first run — the farm portal will show the device as
  /// "pending" until the user approves it.
  Future<PairResult> registerForPairing() async {
    final publicKey = await identity.publicKeyBase64;
    final fingerprint = await identity.fingerprint;

    final response = await http.post(
      Uri.parse('$authBaseUrl/api/device/pair'),
      headers: _headers,
      body: jsonEncode({
        'node_id': nodeId,
        'public_key': publicKey,
        'fingerprint': fingerprint,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String? ?? 'pending';
      return PairResult(
        success: true,
        status: status, // 'pending', 'approved', 'rejected'
        message: data['message'] as String? ?? '',
      );
    }

    return PairResult(
      success: false,
      status: 'error',
      message: 'HTTP ${response.statusCode}: ${response.body}',
    );
  }

  /// Check if device has been approved on the farm portal.
  Future<PairResult> checkPairingStatus() async {
    final fingerprint = await identity.fingerprint;

    final response = await http.get(
      Uri.parse('$authBaseUrl/api/device/pair/status?node_id=$nodeId&fingerprint=$fingerprint'),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return PairResult(
        success: true,
        status: data['status'] as String? ?? 'pending',
        message: data['message'] as String?,
      );
    }

    return PairResult(
      success: false,
      status: 'error',
      message: 'HTTP ${response.statusCode}',
    );
  }

  // -----------------------------------------------------------------------
  // Step 2 + 3: Challenge-response authentication
  // -----------------------------------------------------------------------

  /// Authenticate with the auth server using Ed25519 signed challenge.
  /// Returns true if we got a valid session token.
  Future<AuthResult> authenticate() async {
    // Step 2: Get challenge nonce
    final challengeResponse = await http.post(
      Uri.parse('$authBaseUrl/api/device/challenge'),
      headers: _headers,
      body: jsonEncode({'node_id': nodeId}),
    );

    if (challengeResponse.statusCode != 200) {
      return AuthResult(
        success: false,
        error: 'Challenge failed: HTTP ${challengeResponse.statusCode}',
      );
    }

    final challengeData = jsonDecode(challengeResponse.body) as Map<String, dynamic>;
    final challenge = challengeData['challenge'] as String? ?? '';

    if (challenge.isEmpty) {
      return AuthResult(success: false, error: 'Empty challenge from server');
    }

    // Step 3: Sign challenge and exchange for token
    final signature = await identity.signChallenge(challenge);

    final tokenResponse = await http.post(
      Uri.parse('$authBaseUrl/api/device/token'),
      headers: _headers,
      body: jsonEncode({
        'node_id': nodeId,
        'challenge': challenge,
        'signature': signature,
      }),
    );

    if (tokenResponse.statusCode == 200) {
      final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      _accessToken = tokenData['access_token'] as String?;
      _refreshToken = tokenData['refresh_token'] as String?;

      final expiresIn = tokenData['expires_in'] as int? ?? 3600;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

      return AuthResult(success: true);
    }

    return AuthResult(
      success: false,
      error: 'Token exchange failed: HTTP ${tokenResponse.statusCode}: ${tokenResponse.body}',
    );
  }

  // -----------------------------------------------------------------------
  // Token refresh
  // -----------------------------------------------------------------------

  /// Refresh the access token before it expires.
  Future<AuthResult> refreshAccessToken() async {
    if (_refreshToken == null) {
      return AuthResult(success: false, error: 'No refresh token');
    }

    final response = await http.post(
      Uri.parse('$authBaseUrl/api/device/refresh'),
      headers: _headers,
      body: jsonEncode({
        'node_id': nodeId,
        'refresh_token': _refreshToken,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String?;
      final expiresIn = data['expires_in'] as int? ?? 3600;
      _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

      if (data.containsKey('refresh_token')) {
        _refreshToken = data['refresh_token'] as String?;
      }

      return AuthResult(success: true);
    }

    // Refresh failed — need full re-auth
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
    return AuthResult(success: false, error: 'Refresh failed: HTTP ${response.statusCode}');
  }

  /// Check if token needs refresh (within 5 min of expiry).
  bool get needsRefresh =>
      _tokenExpiry != null &&
      DateTime.now().isAfter(_tokenExpiry!.subtract(const Duration(minutes: 5)));

  /// Clear all tokens (logout).
  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
    _tokenExpiry = null;
  }
}

class PairResult {
  final bool success;
  final String status; // 'pending', 'approved', 'rejected', 'error'
  final String? message;

  PairResult({required this.success, required this.status, this.message});
  bool get isApproved => status == 'approved';
  bool get isPending => status == 'pending';
}

class AuthResult {
  final bool success;
  final String? error;

  AuthResult({required this.success, this.error});
}
