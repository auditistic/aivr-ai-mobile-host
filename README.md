
![aivr-mobile-node.png](images/aivr-mobile-node.png)
# AIVR AI Node Mobile

Decentralized AI inference swarm. Turn Android phones and Windows PCs into a mesh of OpenAI-compatible API servers that auto-discover each other and load-balance inference requests.

## System Overview

AIVR-AI-Mobile-Host integrates mobile devices as distributed inference nodes within the AIVR grid. By leveraging the Neural Processing Units (NPUs) in modern smartphones (Pixel, Samsung, iPhone), this system offloads lighter AI tasks from the main servers. It turns otherwise idle phones into active "neurons" that can handle chat completions, summarization, or simple logic tasks, reducing the load on the central GPUs.

This component is crucial for the "Ubiquitous AI" vision of AIVR, ensuring that intelligence is not just centralized in a rack server but distributed across the physical environment. It adds resilience and scalability to the system, allowing for edge computing capabilities that are accessible via standard OpenAI APIs.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    WiFi Network (LAN)                    │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  Android #1   │  │  Android #2   │  │  Windows PC   │  │
│  │  Phone Node   │  │  Phone Node   │  │  Desktop Node │  │
│  │              │  │              │  │              │  │
│  │ Cactus LLM   │  │ Cactus LLM   │  │ Cactus LLM   │  │
│  │ :8080/v1     │  │ :8080/v1     │  │ :8080/v1     │  │
│  │              │  │              │  │              │  │
│  │ SwarmService  │◄─►│ SwarmService  │◄─►│ SwarmService  │  │
│  │ UDP :41900   │  │ UDP :41900   │  │ UDP :41900   │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         ▲                  ▲                  ▲         │
│         └──────────────────┴──────────────────┘         │
│              Auto-discovery via UDP broadcast            │
└─────────────────────────────────────────────────────────┘
```

**How the swarm works:**
- Each device runs the same Flutter app
- On launch, the `SwarmService` broadcasts a UDP heartbeat every 5 seconds on port 41900
- All devices on the same WiFi automatically discover each other
- The SWARM tab shows all connected nodes in real-time
- Use `/v1/swarm/dispatch` to send requests that get auto-routed to available peers
- If a peer fails, requests fall back to local inference

## System Integrations

This mobile mesh connects directly to the core orchestration and service layers.
- [AIVR-App-Wifi-Mesh](../AIVR-App-Wifi-Mesh/README.md): Ensures the consistent low-latency network connectivity required for these mobile nodes to respond quickly.
- [AIVR-AI-Orchestrator](../AIVR-AI-Orchestrator/README.md): Dispatches small, latency-tolerant tasks to these mobile nodes when the main cluster is busy.
- [AIVR-Service-Relay](../AIVR-Service-Relay/README.md): Proxies requests from the public internet to these local mobile endpoints securely.
- [AIVR-Host-Setup](../AIVR-Host-Setup/README.md): Configures the DHCP reservations to ensure these phones have static IPs for reliable API access.
- [AIVR-AI-Worker](../AIVR-AI-Worker/README.md): Can fallback to these mobile nodes if the primary high-end models are unavailable.

## Performance

| Device Type | Expected Speed (Qwen3-0.6B INT8) |
|-------------|----------------------------------|
| Pixel 6a, Galaxy S21, iPhone 11 | 16-20 tok/s |
| Pixel 9, Galaxy S25, iPhone 16 Pro | 50-70 tok/s |
| iPhone 17 Pro (flagships) | 75+ tok/s |

## Quick Deploy: 2 Android + 1 Windows

### Prerequisites

- Windows PC with Flutter SDK + Android Studio installed
- Two Android phones (USB debugging enabled)
- All 3 devices on the same WiFi network
- USB cables for the phones

### Step 1: Install Flutter (One-Time)

```powershell
# Download Flutter SDK from flutter.dev
# Extract to C:\src\flutter
# Add to PATH: C:\src\flutter\bin

flutter doctor
flutter doctor --android-licenses
```

### Step 2: Build Everything

```powershell
# Clone and build all targets at once
git clone https://github.com/AudiTistic/AIVR-Ai-Node-Mobile.git
cd AIVR-Ai-Node-Mobile

# Option A: Use the deploy script (builds Android APK + Windows)
.\deploy.ps1

# Option B: Build manually
cd .mobile
flutter pub get
flutter build apk --release      # Android APK
flutter build windows --release   # Windows desktop
```

### Step 3: Install on All Devices

**Android phones (both):**
```powershell
# USB install (connect each phone)
adb install deploy/aivr-ai-node.apk

# Or copy deploy/aivr-ai-node.apk to each phone and install manually
```

**Windows PC:**
```powershell
# Run directly from build output
.\deploy\windows\cactus_openai_server.exe
```

### Step 4: Form the Swarm

1. Open "AIVR AI Node" on all 3 devices
2. Go to **MODEL** tab, download a model (e.g., Qwen 3 0.6B)
3. Load the model on each device
4. Go to **SWARM** tab -- devices auto-discover within seconds
5. Start the server on each device via the **OPENAI** tab
6. The swarm is now live

### Step 5: Test the Swarm

```python
from openai import OpenAI

# Talk directly to any node
client = OpenAI(
    base_url="http://192.168.1.100:8080/v1",
    api_key="local",
)

response = client.chat.completions.create(
    model="cactus-default",
    messages=[{"role": "user", "content": "Hello from the swarm"}],
    max_tokens=100,
)
print(response.choices[0].message.content)
```

```python
# Or use swarm dispatch (auto-routes to best available node)
import requests

response = requests.post(
    "http://192.168.1.100:8080/v1/swarm/dispatch",
    json={
        "model": "cactus-default",
        "messages": [{"role": "user", "content": "Which node am I on?"}],
    },
)
data = response.json()
print(f"Response: {data['choices'][0]['message']['content']}")
print(f"Routed to: {data.get('_routed_to', 'local')}")
```

### Step 6: Keep Devices Online

- **Phones:** Disable battery optimization, keep plugged in, enable "Stay awake while charging"
- **Windows:** Disable sleep in Power Settings

## API Endpoints

### Standard OpenAI Endpoints
| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/chat/completions` | Chat completion (supports streaming) |
| `GET`  | `/v1/models` | List available models |
| `GET`  | `/` | Health check + node info |

### Swarm Endpoints
| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/v1/swarm/status` | Full swarm status (self + all peers) |
| `GET`  | `/v1/swarm/peers` | List discovered peer nodes |
| `POST` | `/v1/swarm/dispatch` | Send request, auto-routed to best peer |

### Internal Endpoints
| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/v1/internal/devices` | List compute devices (NPU/GPU/CPU) |
| `GET`  | `/v1/internal/stats` | Token usage and performance stats |

## Swarm Discovery Protocol

- **Transport:** UDP broadcast on port 41900
- **Heartbeat interval:** 5 seconds
- **Peer timeout:** 15 seconds (3 missed heartbeats)
- **Protocol ID:** `aivr-swarm-v1`
- **Discovery:** Fully automatic, zero-config on same LAN

Each heartbeat contains:
```json
{
  "proto": "aivr-swarm-v1",
  "node_id": "uuid-v4",
  "ip": "192.168.1.100",
  "port": 8080,
  "platform": "android",
  "active_model": "qwen3-0.6",
  "is_server_running": true,
  "timestamp": "2026-03-26T12:00:00Z"
}
```

## Project Structure

```
AIVR-Ai-Node-Mobile/
├── .mobile/                 # Flutter app (cross-platform)
│   ├── lib/
│   │   ├── main.dart          # App + HTTP server + UI
│   │   ├── models.dart        # Data models
│   │   ├── swarm_service.dart  # Peer discovery & coordination
│   │   └── screens/           # UI screens
│   ├── android/               # Android build config
│   ├── windows/               # Windows build config
│   └── pubspec.yaml           # Flutter dependencies
├── .src/                    # Web dashboard (React/Vite)
├── src/                     # C++ native bridge (FFI)
├── deploy.ps1               # Windows build script
├── deploy.sh                # Linux/CI build script
└── README.md
```

## FAQ

**Q: Do I need a Cactus telemetry token?**
A: Not for basic testing. For production, uncomment the `CactusConfig` line in `main.dart` and add your token.

**Q: Can I use different models on different devices?**
A: Yes. Each node independently downloads and loads models. The swarm tracks which model each peer is running.

**Q: Why not just use Ollama on Termux?**
A: Cactus is 2-10x faster on the same hardware due to ARM-specific kernels.

**Q: Can I run this on iOS?**
A: Yes, but you need a Mac to build. Change `flutter build apk` to `flutter build ios`.

**Q: How do devices find each other?**
A: UDP broadcast on port 41900. All devices on the same WiFi subnet discover each other automatically within 5 seconds.

**Q: What if a node goes offline?**
A: Peers are removed from the swarm after 15 seconds of missed heartbeats. Dispatch requests automatically fall back to other available nodes.

## Contributing

PRs welcome. Focus areas:
- Weighted load balancing (route by model capability + current load)
- Cross-subnet discovery via mDNS
- Inference pipeline chaining across nodes
- Battery optimization profiles

## License

MIT - do whatever you want with this.
