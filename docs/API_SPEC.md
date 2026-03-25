# AI-Mobile-Host — API_SPEC.md

## 1. Flutter-to-C++ (FFI) Interface

### `initialize_mobile_service`
- **Params:** `const char* config_json` — `{ "mesh_host": string, "relay_host": string }`
- **Returns:** `int` — 0 on success, -1 on error.

### `aivr_register_node`
- **Params:** `const char* node_json` — `{ "node_id": string, "ip": string, "port": int, "models": [...] }`
- **Returns:** `const char*` — JSON: `{ "status": "registered", "node_id": string, "mesh": string, "model_count": int }`

### `aivr_deregister_node`
- **Params:** None
- **Returns:** `const char*` — JSON: `{ "status": "deregistered", "node_id": string }`

### `aivr_report_tokens`
- **Params:** `const char* usage_json` — `{ "tokens_in": int, "tokens_out": int, "model_id": string }`
- **Returns:** `void` (fire-and-forget)

### `aivr_update_models`
- **Params:** `const char* models_json` — JSON array of model objects
- **Returns:** `void`

### `aivr_get_models`
- **Returns:** `const char*` — JSON array of currently advertised models

### `aivr_get_node_health`
- **Returns:** `const char*` — JSON: `{ "node_id", "registered", "uptime_seconds", "tokens_in", "tokens_out", "requests_served", "mesh_host", "relay_host", "model_count" }`

### `get_mobile_status`
- **Returns:** `const char*` — Human-readable status string

### `AIVR_Core_Send_Sensor`
- **Params:** `{ "type": string, "values": float[] }`
- **Action:** Packages data into a Relay packet and emits it.

## 2. Platform Channel API (Native)

### `method: getBiometricAuth`
- **Output:** `{ "token": string, "error": string }`
- **Description:** Invokes Android BiometricPrompt or iOS LocalAuthentication.

### `method: startBackgroundService`
- **Description:** Keeps the Mesh thread alive when the app is minimized.

## 3. OpenAI-Compatible REST API (Port 8080)

### `POST /v1/chat/completions`
- **Auth:** Optional Bearer token
- **Body:** `{ "model": string, "messages": [...], "temperature": float, "max_tokens": int, "stream": bool }`
- **Response:** OpenAI-format chat completion (or SSE stream)

### `GET /v1/models`
- **Auth:** Optional Bearer token
- **Response:** `{ "object": "list", "data": [{ "id", "object", "created", "owned_by", "meta": {...} }] }`

### `GET /v1/internal/devices`
- **Auth:** Optional Bearer token
- **Response:** `{ "object": "list", "data": [{ "id": "NPU1", "type", "pci_link", "status" }] }`

### `GET /v1/internal/stats`
- **Auth:** Optional Bearer token
- **Response:** `{ "uptime_seconds", "request_count", "tokens_in", "tokens_out", "earned", "token_speed", "pending_requests", "model_id", "node_id", "registered", "mesh" }`

### `GET /`
- **Auth:** None (health check)
- **Response:** `{ "status", "model", "version", "uptime", "requests", "active_requests", "tokens_per_second", "node_id", "aivr_registered" }`

## 4. Error Response Format
All error responses follow the OpenAI standard:
```json
{
  "error": {
    "message": "Human-readable description",
    "type": "invalid_request_error | server_error",
    "code": "error_code"
  }
}
```

## 5. Remote Control Interface (REST/WS)
- `GET /api/remote/status`: Hub state for mobile visualization.
- `POST /api/remote/agent`: Commands an agent from the mobile UI.

## 6. Notification Hooks
- `method: pushNotification`: Receives security or task alerts from the Orchestrator.

## 7. Health & Battery
- `GET /health`: Mobile-specific metrics; includes `battery_level` and `signal_strength`.

## 8. Image Upload API
- `POST /api/upload/photo`: Directly uploads a camera snapshot to `AI-Codex` for analysis.

## 9. QR Handshake
- `method: scanHubQR`: Parses the Hub's connection string and auto-configures the Mesh service.

## 10. Error Codes (Mobile-Specific)
- `ERR_PLATFORM_CHANNEL_TIMEOUT`: Native side didn't respond.
- `ERR_PERMISSION_DENIED`: Camera/GPS permission missing.
- `ERR_MESH_LOST`: LAN connection dropped.

## 11. Packet Headers
Standard Axon `0xACE1` framing.

## 12. Authentication
- **Mobile Device Secret:** Stored in Android Keystore / iOS Keychain.
- **API Key (OpenAI Bridge):** Optional Bearer token, configurable via Settings. When not set, all requests are accepted (local-only mode).
