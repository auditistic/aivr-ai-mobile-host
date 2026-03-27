import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'device_identity.dart';

/// Persists all device credentials securely.
///
/// Stores: node_id, CF access tokens, JWT tokens, farm endpoint, keypair.
/// In production, private keys and CF secrets should use Android Keystore /
/// iOS Keychain. SharedPreferences used here for cross-platform compat.
class CredentialStore {
  static const _kNodeId = 'cred_node_id';
  static const _kFingerprint = 'cred_fingerprint';
  static const _kAccessToken = 'cred_access_token';
  static const _kRefreshToken = 'cred_refresh_token';
  static const _kCfClientId = 'cred_cf_client_id';
  static const _kCfClientSecret = 'cred_cf_client_secret';
  static const _kFarmId = 'cred_farm_id';
  static const _kFarmName = 'cred_farm_name';
  static const _kFarmEndpoint = 'cred_farm_endpoint';
  static const _kKeyMaterial = 'cred_key_material';
  static const _kPaired = 'cred_paired';

  // In-memory cache
  String? nodeId;
  String? fingerprint;
  String? accessToken;
  String? refreshToken;
  String? cfClientId;
  String? cfClientSecret;
  String? farmId;
  String? farmName;
  String? farmEndpoint;
  KeyMaterial? keyMaterial;
  bool isPaired = false;

  bool get hasCredentials =>
      nodeId != null &&
      accessToken != null &&
      cfClientId != null &&
      cfClientSecret != null;

  bool get hasFarmEndpoint => farmEndpoint != null && farmEndpoint!.isNotEmpty;

  /// Load all credentials from storage.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    nodeId = prefs.getString(_kNodeId);
    fingerprint = prefs.getString(_kFingerprint);
    accessToken = prefs.getString(_kAccessToken);
    refreshToken = prefs.getString(_kRefreshToken);
    cfClientId = prefs.getString(_kCfClientId);
    cfClientSecret = prefs.getString(_kCfClientSecret);
    farmId = prefs.getString(_kFarmId);
    farmName = prefs.getString(_kFarmName);
    farmEndpoint = prefs.getString(_kFarmEndpoint);
    isPaired = prefs.getBool(_kPaired) ?? false;

    final kmJson = prefs.getString(_kKeyMaterial);
    if (kmJson != null) {
      keyMaterial = KeyMaterial.fromJson(jsonDecode(kmJson));
    }
  }

  /// Save credentials from a successful /pair response.
  Future<void> savePairResponse(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();

    nodeId = data['node_id'] as String?;
    fingerprint = data['fingerprint'] as String?;
    accessToken = data['access_token'] as String?;
    refreshToken = data['refresh_token'] as String?;

    final cf = data['cloudflare_access'] as Map<String, dynamic>?;
    if (cf != null) {
      cfClientId = cf['client_id'] as String?;
      cfClientSecret = cf['client_secret'] as String?;
    }

    final farm = data['farm'] as Map<String, dynamic>?;
    if (farm != null) {
      farmId = farm['id'] as String?;
      farmName = farm['name'] as String?;
      farmEndpoint = farm['endpoint'] as String?;
    }

    isPaired = true;

    await prefs.setString(_kNodeId, nodeId ?? '');
    await prefs.setString(_kFingerprint, fingerprint ?? '');
    await prefs.setString(_kAccessToken, accessToken ?? '');
    await prefs.setString(_kRefreshToken, refreshToken ?? '');
    await prefs.setString(_kCfClientId, cfClientId ?? '');
    await prefs.setString(_kCfClientSecret, cfClientSecret ?? '');
    await prefs.setString(_kFarmId, farmId ?? '');
    await prefs.setString(_kFarmName, farmName ?? '');
    await prefs.setString(_kFarmEndpoint, farmEndpoint ?? '');
    await prefs.setBool(_kPaired, true);
  }

  /// Save key material.
  Future<void> saveKeyMaterial(KeyMaterial km) async {
    keyMaterial = km;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKeyMaterial, jsonEncode(km.toJson()));
  }

  /// Update tokens after refresh (rotating refresh token).
  Future<void> updateTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    this.accessToken = accessToken;
    if (refreshToken != null) this.refreshToken = refreshToken;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccessToken, accessToken);
    if (refreshToken != null) {
      await prefs.setString(_kRefreshToken, refreshToken);
    }
  }

  /// Headers for Cloudflare Access + JWT auth.
  /// Use on all /api/device/* requests.
  Map<String, String> get protectedHeaders => {
        'CF-Access-Client-Id': cfClientId ?? '',
        'CF-Access-Client-Secret': cfClientSecret ?? '',
        'Authorization': 'Bearer ${accessToken ?? ''}',
        'User-Agent': 'AIVR-Node/2.1.0',
        'Content-Type': 'application/json',
      };

  /// Headers for pre-auth requests (no CF, no JWT).
  Map<String, String> get publicHeaders => {
        'User-Agent': 'AIVR-Node/2.1.0',
        'Content-Type': 'application/json',
      };

  /// Clear everything (factory reset).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _kNodeId, _kFingerprint, _kAccessToken, _kRefreshToken,
      _kCfClientId, _kCfClientSecret, _kFarmId, _kFarmName,
      _kFarmEndpoint, _kKeyMaterial, _kPaired,
    ]) {
      await prefs.remove(key);
    }
    nodeId = null;
    fingerprint = null;
    accessToken = null;
    refreshToken = null;
    cfClientId = null;
    cfClientSecret = null;
    farmId = null;
    farmName = null;
    farmEndpoint = null;
    keyMaterial = null;
    isPaired = false;
  }
}
