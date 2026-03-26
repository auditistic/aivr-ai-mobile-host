import 'dart:io';
import 'package:path_provider/path_provider.dart';

// Re-export data classes so existing imports still work.
export 'device_capabilities_data.dart';

import 'device_capabilities_data.dart';

/// Platform-specific hardware detection.
/// Uses dart:io — NOT available on web. Web preview uses data classes directly.
class DeviceDetector {
  /// True if running on a desktop platform (Windows/macOS/Linux).
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// True if running on a mobile platform (Android/iOS).
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Gather device capabilities. Only call from native (non-web) targets.
  static Future<DeviceCapabilities> gather() async {
    final cpuCores = Platform.numberOfProcessors;
    final osVersion = Platform.operatingSystemVersion;
    final platform = _detectPlatform();

    final totalRamMb = await _detectRam();
    final availableStorageMb = await _detectStorage();
    final computeResult = await _detectCompute();

    return DeviceCapabilities(
      cpuCores: cpuCores,
      totalRamMb: totalRamMb,
      availableStorageMb: availableStorageMb,
      osVersion: osVersion,
      platform: platform,
      computePreference: computeResult.preference,
      gpuName: computeResult.gpuName,
    );
  }

  // --- Platform detection ---

  static String _detectPlatform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  // --- RAM detection (cross-platform) ---

  static Future<int> _detectRam() async {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        if (match != null) return int.parse(match.group(1)!) ~/ 1024;
      } else if (Platform.isMacOS) {
        final result = await Process.run('sysctl', ['-n', 'hw.memsize']);
        if (result.exitCode == 0) {
          final bytes = int.tryParse(result.stdout.toString().trim()) ?? 0;
          return bytes ~/ (1024 * 1024);
        }
      } else if (Platform.isWindows) {
        final result = await Process.run('wmic', ['ComputerSystem', 'get', 'TotalPhysicalMemory']);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().trim().split('\n');
          if (lines.length > 1) {
            final bytes = int.tryParse(lines.last.trim()) ?? 0;
            return bytes ~/ (1024 * 1024);
          }
        }
      }
    } catch (_) {}
    return 4096;
  }

  // --- Storage detection (cross-platform) ---

  static Future<int> _detectStorage() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      if (Platform.isWindows) {
        final drive = appDir.path.substring(0, 2);
        final result = await Process.run('wmic', [
          'logicaldisk', 'where', 'DeviceID="$drive"', 'get', 'FreeSpace'
        ]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().trim().split('\n');
          if (lines.length > 1) {
            final bytes = int.tryParse(lines.last.trim()) ?? 0;
            return bytes ~/ (1024 * 1024);
          }
        }
      } else {
        final result = await Process.run('df', ['-k', appDir.path]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          if (lines.length > 1) {
            final parts = lines[1].split(RegExp(r'\s+'));
            if (parts.length >= 4) {
              return (int.tryParse(parts[3]) ?? 0) ~/ 1024;
            }
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  // --- Compute unit detection (cross-platform) ---

  static Future<_ComputeResult> _detectCompute() async {
    try {
      if (Platform.isAndroid) return await _detectComputeAndroid();
      if (Platform.isMacOS) return await _detectComputeMacOS();
      if (Platform.isWindows) return await _detectComputeWindows();
      if (Platform.isLinux) return await _detectComputeLinux();
    } catch (_) {}
    return _ComputeResult(ComputePreference.cpu, null);
  }

  static Future<_ComputeResult> _detectComputeAndroid() async {
    final npuPaths = ['/sys/class/misc/adsprpc-smd', '/sys/devices/platform/soc/soc:qcom,dsp'];
    for (final path in npuPaths) {
      if (await File(path).exists()) {
        return _ComputeResult(ComputePreference.npu, 'Qualcomm Hexagon NPU');
      }
    }
    if (await File('/dev/kgsl-3d0').exists()) return _ComputeResult(ComputePreference.gpu, 'Qualcomm Adreno GPU');
    if (await File('/dev/mali0').exists()) return _ComputeResult(ComputePreference.gpu, 'ARM Mali GPU');
    return _ComputeResult(ComputePreference.cpu, null);
  }

  static Future<_ComputeResult> _detectComputeMacOS() async {
    final result = await Process.run('sysctl', ['-n', 'machdep.cpu.brand_string']);
    final brand = result.stdout.toString().trim();
    final siliconCheck = await Process.run('sysctl', ['-n', 'hw.optional.arm64']);
    if (siliconCheck.exitCode == 0 && siliconCheck.stdout.toString().trim() == '1') {
      return _ComputeResult(ComputePreference.npu, 'Apple Neural Engine ($brand)');
    }
    return _ComputeResult(ComputePreference.gpu, 'Metal GPU ($brand)');
  }

  static Future<_ComputeResult> _detectComputeWindows() async {
    try {
      final npuCheck = await Process.run('wmic', ['path', 'Win32_PnPEntity', 'where', 'Name like "%NPU%"', 'get', 'Name']);
      if (npuCheck.exitCode == 0 && npuCheck.stdout.toString().contains('NPU')) {
        final name = npuCheck.stdout.toString().split('\n').where((l) => l.trim().isNotEmpty && !l.contains('Name')).firstOrNull?.trim();
        return _ComputeResult(ComputePreference.npu, name ?? 'Intel NPU');
      }
    } catch (_) {}
    try {
      final gpuCheck = await Process.run('wmic', ['path', 'Win32_VideoController', 'get', 'Name']);
      if (gpuCheck.exitCode == 0) {
        final lines = gpuCheck.stdout.toString().split('\n').where((l) => l.trim().isNotEmpty && !l.contains('Name')).toList();
        if (lines.isNotEmpty) {
          final gpuName = lines.first.trim();
          if (gpuName.contains('NVIDIA') || gpuName.contains('AMD') || gpuName.contains('Arc')) {
            return _ComputeResult(ComputePreference.gpu, gpuName);
          }
        }
      }
    } catch (_) {}
    return _ComputeResult(ComputePreference.cpu, null);
  }

  static Future<_ComputeResult> _detectComputeLinux() async {
    try {
      final result = await Process.run('nvidia-smi', ['--query-gpu=name', '--format=csv,noheader']);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        return _ComputeResult(ComputePreference.gpu, 'NVIDIA ${result.stdout.toString().trim()}');
      }
    } catch (_) {}
    try {
      if (await Directory('/sys/class/accel').exists()) {
        return _ComputeResult(ComputePreference.npu, 'Intel NPU (accel)');
      }
    } catch (_) {}
    try {
      if (await Directory('/dev/dri').exists()) return _ComputeResult(ComputePreference.gpu, 'GPU (via DRI)');
    } catch (_) {}
    return _ComputeResult(ComputePreference.cpu, null);
  }
}

class _ComputeResult {
  final ComputePreference preference;
  final String? gpuName;
  _ComputeResult(this.preference, this.gpuName);
}
