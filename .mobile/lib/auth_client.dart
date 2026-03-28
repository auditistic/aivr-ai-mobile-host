import 'dart:convert';
import 'package:flutter/foundation.dart';
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

  // CSRF token (fetched before POST requests if server requires it)
  String? _csrfToken;

  // -----------------------------------------------------------------------
  // CSRF handling
  // -----------------------------------------------------------------------

  /// Fetch CSRF token from the auth server.
  /// Tries GET /api/auth/csrf or /api/csrf — common patterns.
  Future<void> _fetchCsrfToken() async {
    try {
      final response = await http.get(
        Uri.parse('$authBaseUrl/api/auth/csrf'),
        headers: credentials.publicHeaders,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _csrfToken = data['csrfToken'] as String? ?? data['token'] as String?;
      }
    } catch (_) {
      // CSRF not required — continue without it
    }
  }

  /// Add CSRF token to headers if available.
  Map<String, String> _withCsrf(Map<String, String> headers) {
    if (_csrfToken != null) {
      return {...headers, 'X-CSRF-Token': _csrfToken!};
    }
    return headers;
  }

  // -----------------------------------------------------------------------
  // PRE-AUTH: Pairing (no CF headers needed)
  // -----------------------------------------------------------------------

  /// POST /api/auth/device/pair
  Future<PairResult> pair(String pairingCode) async {
    // Fetch CSRF token first if needed
    await _fetchCsrfToken();

    final publicKey = identity.publicKeySpkiBase64;

    debugPrint('[AUTH] Pairing with code: "$pairingCode" (${pairingCode.length} chars)');
    debugPrint('[AUTH] Public key length: ${publicKey.length}');
    debugPrint('[AUTH] POST $authBaseUrl/api/auth/device/pair');

    final response = await http.post(
      Uri.parse('$authBaseUrl/api/auth/device/pair'),
      headers: _withCsrf(credentials.publicHeaders),
      body: jsonEncode({
        'public_key': publicKey,
        'pairing_code': pairingCode,
      }),
    );

    debugPrint('[AUTH] Response: ${response.statusCode} ${response.body.substring(0, response.body.length.clamp(0, 200))}');

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
  // PRE-AUTH: Reauth (no CF headers needed — uses ECDSA challenge-response)
  // -----------------------------------------------------------------------

  /// POST /api/auth/device/reauth
  ///
  /// Two-phase challenge-response for when JWT and refresh token are both
  /// expired but the device is still approved. Uses the stored private key.
  /// No CF headers needed (pre-auth endpoint).
  Future<AuthResult> reauth() async {
    if (credentials.nodeId == null) {
      return AuthResult(success: false, error: 'No node_id');
    }

    debugPrint('[AUTH] Reauth phase 1: requesting challenge for ${credentials.nodeId}');

    // Phase 1: Request challenge
    final challengeRes = await http.post(
      Uri.parse('$authBaseUrl/api/auth/device/reauth'),
      headers: credentials.publicHeaders,
      body: jsonEncode({'node_id': credentials.nodeId}),
    );

    if (challengeRes.statusCode == 403) {
      debugPrint('[AUTH] Reauth: device revoked');
      return AuthResult(success: false, error: 'Device revoked', requiresRepair: true);
    }
    if (challengeRes.statusCode != 200) {
      debugPrint('[AUTH] Reauth challenge failed: ${challengeRes.statusCode}');
      return AuthResult(success: false, error: 'Reauth challenge failed: HTTP ${challengeRes.statusCode}');
    }

    final challengeData = jsonDecode(challengeRes.body) as Map<String, dynamic>;
    final challenge = challengeData['challenge'] as String? ?? '';
    if (challenge.isEmpty) {
      return AuthResult(success: false, error: 'Empty challenge from server');
    }

    // Phase 2: Sign challenge and submit
    final signature = identity.signNonce(challenge);
    debugPrint('[AUTH] Reauth phase 2: submitting signed challenge');

    final tokenRes = await http.post(
      Uri.parse('$authBaseUrl/api/auth/device/reauth'),
      headers: credentials.publicHeaders,
      body: jsonEncode({
        'node_id': credentials.nodeId,
        'challenge': challenge,
        'signature': signature,
      }),
    );

    if (tokenRes.statusCode == 200) {
      final data = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      await credentials.updateTokens(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String?,
      );
      debugPrint('[AUTH] Reauth successful');
      return AuthResult(success: true);
    }

    if (tokenRes.statusCode == 403) {
      return AuthResult(success: false, error: 'Device revoked', requiresRepair: true);
    }
    if (tokenRes.statusCode == 401) {
      return AuthResult(success: false, error: _parseError(tokenRes));
    }

    return AuthResult(success: false, error: 'Reauth failed: HTTP ${tokenRes.statusCode}');
  }

  // -----------------------------------------------------------------------
  // SMART AUTH: Try all methods in priority order
  // -----------------------------------------------------------------------

  /// Attempt authentication using the priority order from the API spec:
  ///   1. Existing JWT (if not expired)
  ///   2. Refresh token
  ///   3. Reauth (ECDSA challenge-response, no CF needed)
  ///   4. Re-pair (only if device was revoked)
  ///
  /// Returns success if any method works. Sets requiresRepair only if
  /// the device has been revoked and needs a new pairing code.
  Future<AuthResult> ensureAuthenticated() async {
    // 1. Check if existing JWT is still valid (we don't decode it,
    //    but if we have one and it was saved recently, try using it)
    if (credentials.accessToken != null) {
      debugPrint('[AUTH] Have existing JWT, will try it');
      // We can't decode HS256 client-side to check expiry,
      // so we just try using it. If it fails, we refresh.
    }

    // 2. Try refresh token
    if (credentials.refreshToken != null) {
      debugPrint('[AUTH] Trying refresh token...');
      final result = await refreshAccessToken();
      if (result.success) {
        debugPrint('[AUTH] Refresh succeeded');
        return result;
      }
      if (result.requiresRepair) {
        debugPrint('[AUTH] Refresh says device revoked');
        return result;
      }
      debugPrint('[AUTH] Refresh failed: ${result.error}');
    }

    // 3. Try reauth (ECDSA challenge-response)
    if (credentials.nodeId != null && identity.hasKeyPair) {
      debugPrint('[AUTH] Trying reauth (challenge-response)...');
      final result = await reauth();
      if (result.success) {
        debugPrint('[AUTH] Reauth succeeded');
        return result;
      }
      if (result.requiresRepair) {
        debugPrint('[AUTH] Reauth says device revoked — need re-pair');
        return result;
      }
      debugPrint('[AUTH] Reauth failed: ${result.error}');
    }

    // 4. All methods failed — but DON'T require re-pair unless device was revoked.
    // Could be a network issue. Keep credentials and let the app retry.
    debugPrint('[AUTH] All auth methods failed — will retry later');
    return AuthResult(success: false, error: 'All auth methods failed — will retry');
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
      return AuthResult(success: false, error: 'No refresh token');
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
