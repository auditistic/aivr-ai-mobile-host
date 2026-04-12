![aivr-mobile-node.png](images/aivr-mobile-node.png)
# AIVR - Node

A dedicated distributed-inference worker node for the AIVR AI Farm. Pair any supported device to the farm with a 6-digit code and start earning tokens by contributing its compute to the mesh.

## Supported Platforms

| Platform | Status |
|----------|--------|
| **Android** | Supported |
| **Windows (PC)** | Supported |
| **Linux** | Supported |
| **iPhone (iOS)** | Coming Soon |
| **Mac (macOS)** | Coming Soon |

Any old phone, a spare Linux box, or your Windows gaming PC can be turned into a token-earning farm node. iPhone and Mac builds are in final packaging — coming soon.

## How It Works

1. **Install** AIVR - Node on your device
2. **Pair** it with a 6-digit code from [auth.aivr.site](https://auth.aivr.site) → Profile → Devices
3. **Connect** the node authenticates via ECDSA P-256 challenge and joins the farm through the Cloudflare gateway
4. **Earn** the farm dispatches inference work; tokens accumulate as your device processes requests
5. **Spend or trade** tokens power your own AI usage or trade them on the token exchange

## Status Dashboard

The app is headless-ready with a single read-only status screen showing:
- Connection state + farm gateway endpoint
- Node ID and platform
- Active model + compute unit (NPU / GPU / CPU)
- Live token earnings counter
- Tokens in/out, request count, current tok/s
- Activity log

No user configuration, no model pickers, no manual controls — the farm orchestrates everything.

## Architecture

```
┌──────────────┐        WSS + JWT        ┌──────────────────┐
│  AIVR Node   │ ───────────────────────▶│  Cloudflare GW   │
│ (this repo)  │ ◀─── commands, work ────│  + AIVR Farm     │
└──────────────┘                          └──────────────────┘
       │
       ├─ Ed25519/ECDSA keypair (device identity)
       ├─ Cactus LLM inference engine
       └─ Platform-specific compute detection
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## Build & Deploy

### Android
```powershell
cd .mobile
flutter pub get
flutter build apk --release
adb install build\app\outputs\flutter-apk\app-release.apk
```

### Windows / Linux (Flutter GUI)
```bash
cd .mobile
flutter pub get
flutter run -d windows   # or: flutter run -d linux
```

### Headless (servers, Docker, systemd)
```bash
cd .mobile
dart run lib/main_headless.dart
# or with custom farm:
AIVR_FARM_URL=wss://custom.farm/ws/node dart run lib/main_headless.dart
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for setup, [docs/OPERATIONS.md](docs/OPERATIONS.md) for deployment.

## Token Economy

Users earn tokens by contributing their device's compute to the farm. Earned tokens can be:
- **Spent** on their own AI usage through AIVR
- **Traded** on the AIVR token exchange

The more compute you contribute (bigger NPU, better GPU, more uptime) the more tokens you earn.

## System Integrations

- [AIVR-SSO-OAuth](https://auth.aivr.site) — device pairing & JWT auth
- AIVR Farm Gateway — WebSocket command/response channel
- AIVR-AI-Orchestrator — dispatches inference work to paired nodes
- AIVR Token Exchange — credits earned tokens to the user's balance

## License

MIT.
