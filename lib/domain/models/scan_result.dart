import 'package:pocket_extract/domain/models/recoverable_file.dart';

class ScanResult {
  ScanResult({
    required this.files,
    required this.totalBytes,
    required this.unreadableEntries,
    required this.skippedByQuickMode,
    required this.extensionCounts,
  });

  final List<RecoverableFile> files;
  final int totalBytes;
  final int unreadableEntries;
  final int skippedByQuickMode;
  final Map<String, int> extensionCounts;
}

Map<String, int> buildExtensionCounts(List<RecoverableFile> files) {
  final counts = <String, int>{};
  for (final file in files) {
    final ext = file.extension.trim().toLowerCase();
    final key = ext.isEmpty ? 'autre' : ext;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}
