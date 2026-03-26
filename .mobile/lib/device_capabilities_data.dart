/// Preferred compute unit for inference (farm uses this for model assignment).
enum ComputePreference { npu, gpu, cpu }

/// Pure data class — no platform imports. Safe for web.
class DeviceCapabilities {
  final int cpuCores;
  final int totalRamMb;
  final int availableStorageMb;
  final String osVersion;
  final String platform; // 'android' | 'ios' | 'windows' | 'macos' | 'linux' | 'web'
  final ComputePreference computePreference;
  final String? gpuName;
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

  Map<String, dynamic> toJson() => {
        'cpu_cores': cpuCores,
        'total_ram_mb': totalRamMb,
        'available_storage_mb': availableStorageMb,
        'os_version': osVersion,
        'platform': platform,
        'compute_preference': computePreference.name,
        'gpu_name': gpuName,
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
