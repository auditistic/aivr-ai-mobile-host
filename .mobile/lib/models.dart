/// Minimal model info — the farm controls which models are deployed.
/// This just tracks what's on-device.
class ModelInfo {
  final String id;
  final String name;
  final String size;
  final String contextWindow;
  final String quantization;
  final String vram;
  bool isDownloaded;

  ModelInfo({
    required this.id,
    required this.name,
    required this.size,
    this.contextWindow = '32k',
    this.quantization = 'Q8',
    this.vram = '2.0 GB',
    this.isDownloaded = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'context_window': contextWindow,
        'quantization': quantization,
        'vram': vram,
        'is_downloaded': isDownloaded,
      };
}
