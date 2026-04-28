class RecoverableFile {
  RecoverableFile({
    required this.fullPath,
    required this.relativePath,
    required this.sizeBytes,
    required this.extension,
    required this.lastModified,
    this.isCarved = false,
    this.carveStart,
    this.carveEnd,
    this.rawSourcePath,
  });

  final String fullPath;
  final String relativePath;
  final int sizeBytes;
  final String extension;
  final DateTime lastModified;
  final bool isCarved;
  final int? carveStart;
  final int? carveEnd;
  final String? rawSourcePath;
}
