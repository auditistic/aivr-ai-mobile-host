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
  final String platform; // 'android' | 'ios' | 'windows'
  final ComputePreference computePreference;
  List<DownloadedModel> downloadedModels;

  DeviceCapabilities({
    required this.cpuCores,
    required this.totalRamMb,
    required this.availableStorageMb,
    required this.osVersion,
    required this.platform,
    this.computePreference = ComputePreference.cpu,
    this.downloadedModels = const [],
  });

  static Future<DeviceCapabilities> gather() async {
    final cpuCores = Platform.numberOfProcessors;
    final osVersion = Platform.operatingSystemVersion;
    final platform = Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'unknown');

    // RAM: read /proc/meminfo on Android, estimate on iOS
    int totalRamMb = 0;
    try {
      if (Platform.isAndroid) {
        final meminfo = await File('/proc/meminfo').readAsString();
        final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
        if (match != null) {
          totalRamMb = int.parse(match.group(1)!) ~/ 1024;
        }
      } else {
        // Fallback estimate
        totalRamMb = 4096;
      }
    } catch (_) {
      totalRamMb = 4096; // Conservative default
    }

    // Available storage
    int availableStorageMb = 0;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final stat = await FileStat.stat(appDir.path);
      // FileStat doesn't give free space — use df-style approach
      final result = await Process.run('df', [appDir.path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length > 1) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            // Available is typically 4th column in 1K blocks
            availableStorageMb = (int.tryParse(parts[3]) ?? 0) ~/ 1024;
          }
        }
      }
    } catch (_) {
      availableStorageMb = 0;
    }

    // Detect compute preference:
    // - NPU preferred on modern Android (Snapdragon 8 Gen 2+, Tensor G3+, etc.)
    // - GPU fallback, CPU as last resort
    // The farm may override this based on model compatibility.
    ComputePreference compute = ComputePreference.cpu;
    try {
      if (Platform.isAndroid) {
        // Check for NPU presence via sysfs (Qualcomm Hexagon, Google TPU, etc.)
        final npuPaths = [
          '/sys/class/misc/adsprpc-smd', // Qualcomm Hexagon DSP/NPU
          '/dev/mali0',                   // ARM Mali GPU (can proxy NPU)
        ];
        for (final path in npuPaths) {
          if (await File(path).exists()) {
            compute = ComputePreference.npu;
            break;
          }
        }
        if (compute == ComputePreference.cpu) {
          // Fallback: check for GPU
          if (await File('/dev/kgsl-3d0').exists() || // Qualcomm Adreno
              await File('/dev/mali0').exists()) {     // ARM Mali
            compute = ComputePreference.gpu;
          }
        }
      }
    } catch (_) {
      // Default to CPU if detection fails
    }

    return DeviceCapabilities(
      cpuCores: cpuCores,
      totalRamMb: totalRamMb,
      availableStorageMb: availableStorageMb,
      osVersion: osVersion,
      platform: platform,
      computePreference: compute,
    );
  }

  Map<String, dynamic> toJson() => {
        'cpu_cores': cpuCores,
        'total_ram_mb': totalRamMb,
        'available_storage_mb': availableStorageMb,
        'os_version': osVersion,
        'platform': platform,
        'compute_preference': computePreference.name,
        'downloaded_models': downloadedModels.map((m) => m.toJson()).toList(),
      };
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
