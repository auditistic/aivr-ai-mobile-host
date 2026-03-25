import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Preferred compute unit for inference (farm uses this for model assignment).
enum ComputePreference { npu, gpu, cpu }

/// Device hardware capabilities reported to the AI Farm for routing decisions.
class DeviceCapabilities {
  final int cpuCores;
  final int totalRamMb;
  final int availableStorageMb;
  final String osVersion;
  final String platform; // 'android' | 'ios' | 'windows' | 'macos' | 'linux'
  final ComputePreference computePreference;
  final String? gpuName; // e.g. "NVIDIA RTX 4090", "Apple M2", "Intel Arc"
  List<DownloadedModel> downloadedModels;

  DeviceCapabilities({
    required this.cpuCores,
    required this.totalRamMb,
    required this.availableStorageMb,
    required this.osVersion,
    required this.platform,
    this.computePreference = ComputePreference.cpu,
    this.gpuName,
    this.downloadedModels = const [],
  });

  /// True if running on a desktop platform (Windows/macOS/Linux).
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// True if running on a mobile platform (Android/iOS).
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

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

  Map<String, dynamic> toJson() => {
        'cpu_cores': cpuCores,
        'total_ram_mb': totalRamMb,
        'available_storage_mb': availableStorageMb,
        'os_version': osVersion,
        'platform': platform,
        'compute_preference': computePreference.name,
        'gpu_name': gpuName,
        'is_desktop': isDesktop,
        'downloaded_models': downloadedModels.map((m) => m.toJson()).toList(),
      };

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
        // /proc/meminfo works on both Android and Linux
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
    return 4096; // Conservative default
  }

  // --- Storage detection (cross-platform) ---

  static Future<int> _detectStorage() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();

      if (Platform.isWindows) {
        // Use wmic or PowerShell for free disk space
        final drive = appDir.path.substring(0, 2); // e.g. "C:"
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
        // df works on Android, Linux, macOS
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
      // --- Android: NPU/GPU via sysfs ---
      if (Platform.isAndroid) {
        return await _detectComputeAndroid();
      }

      // --- macOS: Apple Neural Engine (ANE) + Metal GPU ---
      if (Platform.isMacOS) {
        return await _detectComputeMacOS();
      }

      // --- Windows: Intel NPU, NVIDIA/AMD GPU ---
      if (Platform.isWindows) {
        return await _detectComputeWindows();
      }

      // --- Linux: NVIDIA GPU, Intel NPU ---
      if (Platform.isLinux) {
        return await _detectComputeLinux();
      }
    } catch (_) {}

    return _ComputeResult(ComputePreference.cpu, null);
  }

  static Future<_ComputeResult> _detectComputeAndroid() async {
    // Qualcomm Hexagon DSP/NPU
    final npuPaths = [
      '/sys/class/misc/adsprpc-smd',
      '/sys/devices/platform/soc/soc:qcom,dsp',
    ];
    for (final path in npuPaths) {
      if (await File(path).exists()) {
        return _ComputeResult(ComputePreference.npu, 'Qualcomm Hexagon NPU');
      }
    }
    // GPU fallback
    if (await File('/dev/kgsl-3d0').exists()) {
      return _ComputeResult(ComputePreference.gpu, 'Qualcomm Adreno GPU');
    }
    if (await File('/dev/mali0').exists()) {
      return _ComputeResult(ComputePreference.gpu, 'ARM Mali GPU');
    }
    return _ComputeResult(ComputePreference.cpu, null);
  }

  static Future<_ComputeResult> _detectComputeMacOS() async {
    // All Apple Silicon Macs have the Neural Engine
    final result = await Process.run('sysctl', ['-n', 'machdep.cpu.brand_string']);
    final brand = result.stdout.toString().trim();

    // Check if Apple Silicon (M1/M2/M3/M4 — all have ANE)
    final siliconCheck = await Process.run('sysctl', ['-n', 'hw.optional.arm64']);
    if (siliconCheck.exitCode == 0 && siliconCheck.stdout.toString().trim() == '1') {
      return _ComputeResult(ComputePreference.npu, 'Apple Neural Engine ($brand)');
    }

    // Intel Mac with discrete GPU
    return _ComputeResult(ComputePreference.gpu, 'Metal GPU ($brand)');
  }

  static Future<_ComputeResult> _detectComputeWindows() async {
    // Check for Intel NPU (Meteor Lake, Lunar Lake, Arrow Lake)
    try {
      final npuCheck = await Process.run('wmic', ['path', 'Win32_PnPEntity', 'where',
        'Name like "%NPU%"', 'get', 'Name']);
      if (npuCheck.exitCode == 0 && npuCheck.stdout.toString().contains('NPU')) {
        final name = npuCheck.stdout.toString().split('\n')
            .where((l) => l.trim().isNotEmpty && !l.contains('Name'))
            .firstOrNull?.trim();
        return _ComputeResult(ComputePreference.npu, name ?? 'Intel NPU');
      }
    } catch (_) {}

    // Check for NVIDIA or AMD GPU
    try {
      final gpuCheck = await Process.run('wmic', ['path', 'Win32_VideoController', 'get', 'Name']);
      if (gpuCheck.exitCode == 0) {
        final lines = gpuCheck.stdout.toString().split('\n')
            .where((l) => l.trim().isNotEmpty && !l.contains('Name'))
            .toList();
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
    // Check for NVIDIA GPU
    try {
      final result = await Process.run('nvidia-smi', ['--query-gpu=name', '--format=csv,noheader']);
      if (result.exitCode == 0) {
        final name = result.stdout.toString().trim();
        if (name.isNotEmpty) {
          return _ComputeResult(ComputePreference.gpu, 'NVIDIA $name');
        }
      }
    } catch (_) {}

    // Check for Intel NPU via accel subsystem
    try {
      final accel = Directory('/sys/class/accel');
      if (await accel.exists()) {
        return _ComputeResult(ComputePreference.npu, 'Intel NPU (accel)');
      }
    } catch (_) {}

    // Check for AMD GPU via /dev/dri
    try {
      final dri = Directory('/dev/dri');
      if (await dri.exists()) {
        final result = await Process.run('lspci', ['-nn']);
        if (result.exitCode == 0) {
          final output = result.stdout.toString();
          if (output.contains('NVIDIA')) {
            return _ComputeResult(ComputePreference.gpu, 'NVIDIA GPU');
          }
          if (output.contains('AMD') && output.contains('VGA')) {
            return _ComputeResult(ComputePreference.gpu, 'AMD GPU');
          }
        }
        return _ComputeResult(ComputePreference.gpu, 'GPU (via DRI)');
      }
    } catch (_) {}

    return _ComputeResult(ComputePreference.cpu, null);
  }
}

class _ComputeResult {
  final ComputePreference preference;
  final String? gpuName;
  _ComputeResult(this.preference, this.gpuName);
}

class DownloadedModel {
  final String id;
  final String name;
  final int sizeMb;

  const DownloadedModel({
    required this.id,
    required this.name,
    required this.sizeMb,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size_mb': sizeMb,
      };
}
