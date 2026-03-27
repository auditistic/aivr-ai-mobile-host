# AIVR - Node — API_SPEC.md

## 1. WebSocket Protocol (Farm ↔ Node)

All communication is JSON over WebSocket via Cloudflare gateway.

**Endpoint:** `wss://farm.aivr.ai/ws/node?node_id={uuid}`

### 1.1 Node → Farm Messages

#### `node_hello` (on connect)
```json
{
  "type": "node_hello",
  "node_id": "uuid",
  "capabilities": {
    "cpu_cores": 8,
    "total_ram_mb": 8192,
    "available_storage_mb": 32000,
    "os_version": "Android 14",
    "platform": "android",
    "downloaded_models": [{"id": "qwen3-0.6", "name": "Qwen 3 0.6B", "size_mb": 1200}]
  },
  "current_model": "qwen3-0.6",
  "model_loaded": true,
  "status": { ... }
}
```

#### `heartbeat` (every 15s)
```json
{
  "type": "heartbeat",
  "node_id": "uuid",
  "uptime": 3600,
  "tokens_in": 50000,
  "tokens_out": 35000,
  "tokens_earned": 80750,
  "requests": 142,
  "pending": 1,
  "token_speed": 24.5,
  "model_id": "qwen3-0.6",
  "model_loaded": true
}
```

#### `command_result`
```json
{
  "type": "command_result",
  "command_id": "cmd-123",
  "node_id": "uuid",
  "status": "ok",
  "message": "Model loaded and ready"
}
```

#### `inference_chunk` (streaming)
```json
{
  "type": "inference_chunk",
  "request_id": "req-456",
  "content": "Hello",
  "index": 0
}
```

#### `inference_complete`
```json
{
  "type": "inference_complete",
  "request_id": "req-456",
  "response": "Hello! How can I help you?",
  "usage": {
    "tokens_in": 15,
    "tokens_out": 8,
    "model_id": "qwen3-0.6",
    "inference_time_ms": 340.0
  }
}
```

#### `token_report`
```json
{
  "type": "token_report",
  "node_id": "uuid",
  "usage": { "tokens_in": 15, "tokens_out": 8, "model_id": "qwen3-0.6" },
  "cumulative": {
    "tokens_in": 50015,
    "tokens_out": 35008,
    "tokens_earned": 80771,
    "request_count": 143
  }
}
```

#### `download_progress`
```json
{
  "type": "download_progress",
  "command_id": "cmd-789",
  "progress": 0.45
}
```

#### `node_goodbye`
```json
{
  "type": "node_goodbye",
  "node_id": "uuid"
}
```

### 1.2 Farm → Node Commands

#### `download_model`
```json
{
  "type": "download_model",
  "command_id": "cmd-789",
  "model_id": "qwen3-0.6",
  "download_url": "https://..."
}
```

#### `load_model`
```json
{
  "type": "load_model",
  "command_id": "cmd-790",
  "model_id": "qwen3-0.6",
  "model_name": "Qwen 3 0.6B",
  "context_size": 4096
}
```

#### `unload_model`
```json
{
  "type": "unload_model",
  "command_id": "cmd-791"
}
```

#### `inference`
```json
{
  "type": "inference",
  "command_id": "cmd-800",
  "request_id": "req-456",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is 2+2?"}
  ],
  "stream": false,
  "temperature": 0.7,
  "max_tokens": 512
}
```

#### `report_status`
```json
{
  "type": "report_status",
  "command_id": "cmd-810"
}
```

#### `delete_model`
```json
{
  "type": "delete_model",
  "command_id": "cmd-820",
  "model_id": "qwen3-0.6"
}
```

## 2. Error Responses

All errors use:
```json
{
  "type": "command_result",
  "command_id": "cmd-xxx",
  "status": "error",
  "message": "Human-readable description"
}
```

## 3. Token Economy

- **Earning rate**: 95% of total tokens processed (in + out)
- **Reporting**: Per-request via `token_report`, cumulative in `heartbeat`
- **Usage**: Spend earned tokens on own AI or trade on exchange
- **Farm credits**: Farm server maintains the ledger based on `token_report` messages

## 4. C++ FFI Interface (mobile_bridge.cpp)

Native bridge for future platform-specific optimizations:

| Function | Purpose |
|----------|---------|
| `initialize_mobile_service(config_json)` | Init with mesh/relay config |
| `aivr_register_node(node_json)` | Register on mesh |
| `aivr_report_tokens(usage_json)` | Report token usage |
| `aivr_update_models(models_json)` | Update model list |
| `aivr_get_node_health()` | Health snapshot |
| `get_mobile_status()` | Status string |
