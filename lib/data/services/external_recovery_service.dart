import 'dart:io';

import 'package:pocket_extract/domain/models/external_engine_status.dart';
import 'package:pocket_extract/domain/models/recoverable_file.dart';
import 'package:pocket_extract/domain/models/scan_result.dart';

class ExternalRecoveryService {
  Future<ExternalEngineStatus> inspectEnvironment() async {
    final isAdmin = await _isRunningAsAdmin();
    final photoRecPath = await _findExecutable('photorec_win.exe');
    final testDiskPath = await _findExecutable('testdisk_win.exe');
    return ExternalEngineStatus(
      isAdmin: isAdmin,
      photoRecPath: photoRecPath,
      testDiskPath: testDiskPath,
    );
  }

  Future<bool> launchTool({
    required String executablePath,
    required List<String> args,
  }) async {
    try {
      await Process.start(
        executablePath,
        args,
        runInShell: true,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ScanResult> importRecoveredFiles(String destinationRoot) async {
    final root = Directory(destinationRoot);
    if (!root.existsSync()) {
      return ScanResult(
        files: const [],
        totalBytes: 0,
        unreadableEntries: 0,
        skippedByQuickMode: 0,
        extensionCounts: const {},
      );
    }

    final files = <RecoverableFile>[];
    var unreadable = 0;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (!entity.path.toLowerCase().contains('recup_dir.')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        files.add(
          RecoverableFile(
            fullPath: entity.path,
            relativePath: _safeRelativeToDestination(
              entity.path,
              destinationRoot,
            ),
            sizeBytes: stat.size,
            extension: entity.path.contains('.')
                ? entity.path.split('.').last
                : '',
            lastModified: stat.modified,
          ),
        );
      } on FileSystemException {
        unreadable += 1;
      }
    }

    files.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    final total = files.fold<int>(0, (acc, f) => acc + f.sizeBytes);
    return ScanResult(
      files: files,
      totalBytes: total,
      unreadableEntries: unreadable,
      skippedByQuickMode: 0,
      extensionCounts: buildExtensionCounts(files),
    );
  }

  Future<bool> _isRunningAsAdmin() async {
    if (!Platform.isWindows) {
      return true;
    }
    try {
      final result = await Process.run('cmd', const ['/c', 'net', 'session']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _findExecutable(String executableName) async {
    final localCandidates = [
      'tools\\testdisk\\$executableName',
      'tools\\$executableName',
      executableName,
    ];
    for (final rel in localCandidates) {
      final file = File(rel);
      if (await file.exists()) {
        return file.absolute.path;
      }
    }

    if (!Platform.isWindows) {
      return null;
    }

    try {
      final result = await Process.run('where', [executableName]);
      if (result.exitCode != 0) {
        return null;
      }
      final lines = result.stdout
          .toString()
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return lines.isEmpty ? null : lines.first;
    } catch (_) {
      return null;
    }
  }

  String _safeRelativeToDestination(String fullPath, String destinationRoot) {
    final normalizedRoot = destinationRoot.endsWith('\\')
        ? destinationRoot.substring(0, destinationRoot.length - 1)
        : destinationRoot;
    if (fullPath.startsWith(normalizedRoot)) {
      return fullPath
          .substring(normalizedRoot.length)
          .replaceFirst(RegExp(r'^[\\/]'), '');
    }
    return fullPath.split('\\').last;
  }
}
