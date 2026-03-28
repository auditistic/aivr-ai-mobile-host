import 'dart:convert';
import 'package:http/http.dart' as http;
import 'device_identity.dart';
import 'credential_store.dart';

/// Auth client for auth.aivr.site — matches the AIVR Device Node API spec.
///
/// Two-layer auth:
///   Layer 1: Cloudflare Edge (CF-Access-Client-Id/Secret headers)
///   Layer 2: Application (Bearer JWT)
///
/// Pre-auth endpoints (/api/auth/device/*) don't need CF headers.
/// Protected endpoints (/api/device/*) need both CF headers + JWT.
class AuthClient {
  final String authBaseUrl;
  final DeviceIdentity identity;
  final CredentialStore credentials;

  AuthClient({
    required this.authBaseUrl,
    required this.identity,
    required this.credentials,
  });

  // -----------------------------------------------------------------------
  // PRE-AUTH: Pairing (no CF headers needed)
  // -----------------------------------------------------------------------

  /// POST /api/auth/device/pair
  ///
  /// Register device public key with a 6-digit pairing code from user's profile.
  /// On success, returns node_id, tokens, CF credentials, and farm endpoint.
  Future<PairResult> pair(String pairingCode) async {
    final publicKey = identity.publicKeySpkiBase64;

    final response = await http.post(
      Uri.parse('$authBaseUrl/api/auth/device/pair'),
      headers: credentials.publicHeaders,
      body: jsonEncode({
        'public_key': publicKey,
        'pairing_code': pairingCode,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;

      // Save everything from the pair response
      await credentials.savePairResponse(data);

      return PairResult(
        success: true,
        status: data['status'] as String? ?? 'approved',
        data: data,
      );
    }

    final error = _parseError(response);
    return PairResult(success: false, status: 'error', error: error);
  }

  /// GET /api/auth/device/pair/status
  ///
  /// Poll for approval (future use — current flow auto-approves).
  Future<PairResult> checkPairingStatus() async {
    final response = await http.get(
      Uri.parse(
        '$authBaseUrl/api/auth/device/pair/status'
        '?node_id=${credentials.nodeId}&fingerprint=${credentials.fingerprint}',
      ),
      headers: credentials.publicHeaders,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final status = data['status'] as String? ?? 'pending';

      // If approved, save the full credentials
      if (status == 'approved' && data.containsKey('access_token')) {
        await credentials.savePairResponse(data);
      }

      return PairResult(success: true, status: status, data: data);
    }

    if (response.statusCode == 403) {
      return PairResult(success: false, status: 'revoked', error: 'Device revoked');
    }

    return PairResult(success: false, status: 'error', error: _parseError(response));
  }

  // -----------------------------------------------------------------------
  // PROTECTED: Challenge-Response Auth (needs CF headers)
  // -----------------------------------------------------------------------

  /// POST /api/device/challenge → POST /api/device/token
  ///
  /// Get a nonce, sign it, exchange for fresh JWT.
  Future<AuthResult> authenticateWithChallenge() async {
    // Step 1: Get challenge nonce
    final challengeRes = await http.post(
      Uri.parse('$authBaseUrl/api/device/challenge'),
      headers: credentials.protectedHeaders,
    );

    if (challengeRes.statusCode == 403) {
      return AuthResult(success: false, error: 'CF access denied — re-pair required', requiresRepair: true);
    }
    if (challengeRes.statusCode == 401) {
      return AuthResult(success: false, error: 'JWT expired — refresh first');
    }
    if (challengeRes.statusCode != 200) {
      return AuthResult(success: false, error: 'Challenge failed: HTTP ${challengeRes.statusCode}');
    }

    final challengeData = jsonDecode(challengeRes.body) as Map<String, dynamic>;
    final nonce = challengeData['nonce'] as String? ?? '';
    if (nonce.isEmpty) {
      return AuthResult(success: false, error: 'Empty nonce from server');
    }

    // Step 2: Sign nonce with private key
    final signature = identity.signNonce(nonce);

    // Step 3: Exchange for token
    final tokenRes = await http.post(
      Uri.parse('$authBaseUrl/api/device/token'),
      headers: credentials.protectedHeaders,
      body: jsonEncode({
        'node_id': credentials.nodeId,
        'nonce': nonce,
        'signature': signature,
      }),
    );

    if (tokenRes.statusCode == 200) {
      final data = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      await credentials.updateTokens(
        accessToken: data['access_token'] as String,
      );
      return AuthResult(success: true);
    }

    if (tokenRes.statusCode == 403) {
      return AuthResult(success: false, error: 'Device revoked', requiresRepair: true);
    }

    return AuthResult(success: false, error: 'Token exchange failed: ${_parseError(tokenRes)}');
  }

  // -----------------------------------------------------------------------
  // PROTECTED: Token Refresh (rotating refresh token)
  // -----------------------------------------------------------------------

  /// POST /api/device/refresh
  ///
  /// Refresh expired JWT. IMPORTANT: refresh token rotates — save the new one.
  Future<AuthResult> refreshAccessToken() async {
    if (credentials.refreshToken == null) {
      return AuthResult(success: false, error: 'No refresh token', requiresRepair: true);
    }

    final response = await http.post(
      Uri.parse('$authBaseUrl/api/device/refresh'),
      headers: credentials.protectedHeaders,
      body: jsonEncode({
        'refresh_token': credentials.refreshToken,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      await credentials.updateTokens(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String?, // Rotated!
      );
      return AuthResult(success: true);
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      return AuthResult(
        success: false,
        error: 'Refresh token invalid/revoked — re-pair required',
        requiresRepair: true,
      );
    }

    return AuthResult(success: false, error: 'Refresh failed: HTTP ${response.statusCode}');
  }

  // -----------------------------------------------------------------------
  // PROTECTED: Heartbeat + Telemetry
  // -----------------------------------------------------------------------

  /// POST /api/device/heartbeat
  Future<bool> sendHeartbeat({
    double? cpuUsage,
    double? memoryUsage,
    double? gpuUsage,
    String? gpuModel,
    int? uptimeSeconds,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$authBaseUrl/api/device/heartbeat'),
        headers: credentials.protectedHeaders,
        body: jsonEncode({
          if (cpuUsage != null) 'cpu_usage': cpuUsage,
          if (memoryUsage != null) 'memory_usage': memoryUsage,
          if (gpuUsage != null) 'gpu_usage': gpuUsage,
          if (gpuModel != null) 'gpu_model': gpuModel,
          if (uptimeSeconds != null) 'uptime_seconds': uptimeSeconds,
        }),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/device/data
  Future<bool> sendTelemetry({
    required int tokensProcessed,
    required int tasksCompleted,
    int errors = 0,
    double? avgLatencyMs,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$authBaseUrl/api/device/data'),
        headers: credentials.protectedHeaders,
        body: jsonEncode({
          'type': 'telemetry',
          'metrics': {
            'tokens_processed': tokensProcessed,
            'tasks_completed': tasksCompleted,
            'errors': errors,
            if (avgLatencyMs != null) 'avg_latency_ms': avgLatencyMs,
          },
        }),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/device/status
  Future<Map<String, dynamic>?> getDeviceStatus() async {
    try {
      final response = await http.get(
        Uri.parse('$authBaseUrl/api/device/status'),
        headers: credentials.protectedHeaders,
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  String _parseError(http.Response response) {
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['error'] as String? ?? 'HTTP ${response.statusCode}';
    } catch (_) {
      return 'HTTP ${response.statusCode}: ${response.body}';
    }
  }
}

class PairResult {
  final bool success;
  final String status; // 'approved', 'pending', 'revoked', 'error'
  final String? error;
  final Map<String, dynamic>? data;

  PairResult({required this.success, required this.status, this.error, this.data});
  bool get isApproved => status == 'approved';
}

class AuthResult {
  final bool success;
  final String? error;
  final bool requiresRepair;

  AuthResult({required this.success, this.error, this.requiresRepair = false});
}
