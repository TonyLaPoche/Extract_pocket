class RecoveryReport {
  RecoveryReport({
    required this.copiedCount,
    required this.nonUsableCount,
    required this.failedCount,
    required this.destinationPath,
  });

  final int copiedCount;
  final int nonUsableCount;
  final int failedCount;
  final String destinationPath;
}
