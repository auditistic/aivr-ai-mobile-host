# AIVR Node — HARDWARE_SPEC.md

## Platform Support Matrix

| Platform | Status |
|----------|--------|
| Android | **Supported** |
| Windows (PC) | **Supported** |
| Linux | **Supported** |
| iPhone (iOS) | _Coming Soon_ |
| Mac (macOS) | _Coming Soon_ |

## 1. System Requirements (Android) — Supported
- **OS:** Android 11.0+.
- **Chip:** ARMv8 (64-bit) required for C++ core performance.
- **Sensors:** Accelerometer/Gyroscope (Required for tracking).

## 2. System Requirements (Windows PC) — Supported
- **OS:** Windows 10 64-bit or newer.
- **Compute:** Intel NPU, NVIDIA/AMD GPU, or x86_64 CPU.

## 3. System Requirements (Linux) — Supported
- **OS:** glibc 2.31+ (Ubuntu 20.04+, Debian 11+, Fedora 34+).
- **Compute:** NVIDIA GPU (CUDA 11+), Intel NPU, or x86_64/ARM64 CPU.

## 4. System Requirements (iPhone / iOS) — Coming Soon
- **OS:** iOS 15.0+.
- **Hardware:** iPhone 12 or newer recommended for neural engine support.
- _Build target exists in the repo; official release pending App Store packaging._

## 5. System Requirements (Mac / macOS) — Coming Soon
- **OS:** macOS 12 (Monterey) or newer.
- **Hardware:** Apple Silicon (M1/M2/M3) recommended; Intel Macs supported with reduced NPU capability.
- _Build target exists in the repo; official release pending notarization._

## 3. Memory (RAM)
- **Usage:** < 256MB active.
- **Background:** < 50MB idle in standby.

## 4. Network Access
- **Wi-Fi:** 5GHz (Strongly recommended for audio streaming).
- **Data:** 4G/5G for remote command fallback.

## 5. GPS / Location
- High-accuracy mode must be enabled for "AIVR-Home" geofencing features.

## 6. Biometric Hardware
- Fingerprint scanner or IR Camera (FaceID) for secure system unlocking.

## 7. Battery Impact
- Active Tracking: ~5-10% per hour.
- Background Mesh: < 1% per hour.

## 8. Display Specs
- Tailored for high-DPI Amoled screens (Dark mode default).
- Dynamic Scaling for foldable devices.

## 9. Camera Resolution
- Minimal for SARAi "Vision" (e.g. 720p is enough for agent reasoning).

## 10. Thermal Safety
If phone temperature > 45°C:
1. Disable IMU streaming.
2. Dim screen.
3. Pulse red notification.
