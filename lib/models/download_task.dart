enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

int _lastGeneratedId = 0;

String _newTaskId() {
  final current = DateTime.now().microsecondsSinceEpoch;
  _lastGeneratedId = current > _lastGeneratedId
      ? current
      : _lastGeneratedId + 1;
  return _lastGeneratedId.toString();
}

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
    this.speedBytesPerSecond = 0,
    this.errorMessage,
    this.isStream = false,
    this.requestHeaders = const {},
  });

  final String id;
  final String url;
  final String fileName;
  final String destinationDirectory;
  final DownloadStatus status;
  final DateTime createdAt;
  final int? totalBytes;
  final int receivedBytes;
  final double speedBytesPerSecond;
  final String? errorMessage;
  final bool isStream;
  final Map<String, String> requestHeaders;

  DownloadTask copyWith({
    String? fileName,
    DownloadStatus? status,
    int? totalBytes,
    int? receivedBytes,
    double? speedBytesPerSecond,
    String? errorMessage,
    bool clearError = false,
    bool clearProgress = false,
    Map<String, String>? requestHeaders,
  }) {
    return DownloadTask(
      id: id,
      url: url,
      fileName: fileName ?? this.fileName,
      destinationDirectory: destinationDirectory,
      status: status ?? this.status,
      createdAt: createdAt,
      totalBytes: clearProgress ? null : totalBytes ?? this.totalBytes,
      receivedBytes: clearProgress ? 0 : receivedBytes ?? this.receivedBytes,
      speedBytesPerSecond: clearProgress
          ? 0
          : speedBytesPerSecond ?? this.speedBytesPerSecond,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      isStream: isStream,
      requestHeaders: requestHeaders ?? this.requestHeaders,
    );
  }

  factory DownloadTask.fromUrl(
    String url,
    String destinationDirectory, {
    bool isStream = false,
    String? suggestedFileName,
    Map<String, String> requestHeaders = const {},
  }) {
    final normalizedUrl = url.trim();
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('Expected a valid HTTP or HTTPS URL.');
    }
    final pathSegments = uri.pathSegments;
    final candidate =
        suggestedFileName ?? (pathSegments.isEmpty ? '' : pathSegments.last);
    var name = _safeFileName(candidate.isEmpty ? 'download' : candidate);
    if (isStream) {
      final dot = name.lastIndexOf('.');
      if (dot > 0) name = name.substring(0, dot);
      name = '$name.mkv';
    }

    return DownloadTask(
      id: _newTaskId(),
      url: uri.toString(),
      fileName: name,
      destinationDirectory: destinationDirectory,
      status: DownloadStatus.queued,
      createdAt: DateTime.now(),
      isStream: isStream,
      requestHeaders: Map.unmodifiable(requestHeaders),
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
      speedBytesPerSecond:
          (json['speedBytesPerSecond'] as num?)?.toDouble() ?? 0,
      errorMessage: json['errorMessage'] as String?,
      isStream: json['isStream'] as bool? ?? false,
      requestHeaders: Map<String, String>.from(
        json['requestHeaders'] as Map? ?? const {},
      ),
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
    'speedBytesPerSecond': speedBytesPerSecond,
    'errorMessage': errorMessage,
    'isStream': isStream,
  };

  static String _safeFileName(String value) {
    final safe = value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return safe.isEmpty || safe == '.' || safe == '..' ? 'download' : safe;
  }
}
