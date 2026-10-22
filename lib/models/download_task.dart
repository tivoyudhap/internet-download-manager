enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    required this.destinationDirectory,
    required this.status,
    required this.createdAt,
    this.totalBytes,
    this.receivedBytes = 0,
    this.errorMessage,
  });

  final String id;
  final String url;
  final String fileName;
  final String destinationDirectory;
  final DownloadStatus status;
  final DateTime createdAt;
  final int? totalBytes;
  final int receivedBytes;
  final String? errorMessage;

  factory DownloadTask.fromUrl(String url, String destinationDirectory) {
    final uri = Uri.parse(url);
    final pathSegments = uri.pathSegments;
    final candidate = pathSegments.isEmpty ? '' : pathSegments.last;
    final name = _safeFileName(candidate.isEmpty ? 'download' : candidate);

    return DownloadTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: uri.toString(),
      fileName: name,
      destinationDirectory: destinationDirectory,
      status: DownloadStatus.queued,
      createdAt: DateTime.now(),
    );
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      url: json['url'] as String,
      fileName: json['fileName'] as String,
      destinationDirectory: json['destinationDirectory'] as String,
      status: DownloadStatus.values.byName(json['status'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
      totalBytes: json['totalBytes'] as int?,
      receivedBytes: json['receivedBytes'] as int? ?? 0,
      errorMessage: json['errorMessage'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'fileName': fileName,
    'destinationDirectory': destinationDirectory,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'totalBytes': totalBytes,
    'receivedBytes': receivedBytes,
    'errorMessage': errorMessage,
  };

  static String _safeFileName(String value) {
    final safe = value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return safe.isEmpty || safe == '.' || safe == '..' ? 'download' : safe;
  }
}
