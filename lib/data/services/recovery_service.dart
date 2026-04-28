import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:pocket_extract/domain/enums/recovery_category.dart';
import 'package:pocket_extract/domain/enums/scan_mode.dart';
import 'package:pocket_extract/domain/models/drive_entry.dart';
import 'package:pocket_extract/domain/models/recoverable_file.dart';
import 'package:pocket_extract/domain/models/recovery_report.dart';
import 'package:pocket_extract/domain/models/scan_result.dart';
import 'package:win32/win32.dart';

class RecoveryService {
  List<DriveEntry> getAvailableDrives() {
    final drives = <DriveEntry>[];
    final mountedFromWindows = _readMountedDrivesFromWindows();

    if (mountedFromWindows.isNotEmpty) {
      for (final path in mountedFromWindows) {
        final letter = path.replaceAll(r':\', '');
        drives.add(DriveEntry(path: path, label: 'Lecteur $letter'));
      }
      return drives;
    }

    // Fallback: scan classique si la commande Windows n'est pas disponible.
    for (var letter = 65; letter <= 90; letter++) {
      final driveLetter = String.fromCharCode(letter);
      final path = '$driveLetter:\\';
      final directory = Directory(path);
      try {
        if (directory.existsSync()) {
          drives.add(DriveEntry(path: path, label: 'Lecteur $driveLetter'));
        }
      } on FileSystemException {
        // Le lecteur peut etre present mais illisible (carte SD corrompue).
        drives.add(
          DriveEntry(path: path, label: 'Lecteur $driveLetter (illisible)'),
        );
      }
    }

    return _uniqueDrives(drives);
  }

  Future<ScanResult> scanForRecoverableFiles(
    String rootPath, {
    required ScanMode mode,
    required void Function(double progress, String status) onProgress,
  }) async {
    debugPrint('[SCAN] Start root=$rootPath mode=${mode.name}');
    final root = Directory(rootPath);
    final collected = <RecoverableFile>[];
    var unreadableEntries = 0;
    var visited = 0;
    var skippedByQuickMode = 0;
    final maxQuickFiles = 2000;
    final maxQuickDepth = 3;

    late final StreamSubscription<FileSystemEntity> subscription;
    final completer = Completer<void>();

    try {
      subscription = root
          .list(recursive: true, followLinks: false)
          .listen(
            (entity) async {
              if (entity is! File) {
                return;
              }
              final relativePath = _safeRelativePath(entity.path, rootPath);
              final depth = RegExp(r'\\').allMatches(relativePath).length;
              if (mode == ScanMode.rapide && depth > maxQuickDepth) {
                skippedByQuickMode += 1;
                return;
              }
              visited += 1;
              if (mode == ScanMode.rapide && visited > maxQuickFiles) {
                debugPrint('[SCAN] Quick mode limit reached at $visited files');
                await subscription.cancel();
                if (!completer.isCompleted) {
                  completer.complete();
                }
                return;
              }

              try {
                final stat = await entity.stat();
                collected.add(
                  RecoverableFile(
                    fullPath: entity.path,
                    relativePath: relativePath,
                    sizeBytes: stat.size,
                    extension: entity.path.contains('.')
                        ? entity.path.split('.').last
                        : '',
                    lastModified: stat.modified,
                  ),
                );
              } on FileSystemException {
                // On garde quand meme l'entree: des meta peuvent etre corrompues
                // mais la copie peut encore fonctionner.
                unreadableEntries += 1;
                collected.add(
                  RecoverableFile(
                    fullPath: entity.path,
                    relativePath: relativePath,
                    sizeBytes: 0,
                    extension: entity.path.contains('.')
                        ? entity.path.split('.').last
                        : '',
                    lastModified: DateTime.fromMillisecondsSinceEpoch(0),
                  ),
                );
                debugPrint(
                  '[SCAN] Stat failed, kept candidate: ${entity.path}',
                );
              }

              if (visited % 50 == 0) {
                final progress = (visited % 1000) / 1000;
                onProgress(
                  progress,
                  'Analyse ${_scanModeLabel(mode)}: $visited elements inspectes...',
                );
                debugPrint(
                  '[SCAN] Progress visited=$visited collected=${collected.length} unreadable=$unreadableEntries',
                );
              }
            },
            onError: (error) {
              unreadableEntries += 1;
              debugPrint('[SCAN] Stream error: $error');
            },
            onDone: () => completer.complete(),
            cancelOnError: false,
          );
    } on FileSystemException {
      debugPrint('[SCAN] Root listing failed for $rootPath');
      onProgress(1, 'Lecteur inaccessible: volume corrompu ou non lisible.');
      return ScanResult(
        files: const [],
        totalBytes: 0,
        unreadableEntries: 1,
        skippedByQuickMode: 0,
        extensionCounts: const {},
      );
    }

    await completer.future;
    await subscription.cancel();

    if (collected.isEmpty) {
      debugPrint(
        '[SCAN] Primary scan found 0, trying Windows fallback dir /s /b',
      );
      final fallbackCandidates = _scanUsingWindowsDir(rootPath, mode: mode);
      collected.addAll(fallbackCandidates);
      debugPrint(
        '[SCAN] Fallback found ${fallbackCandidates.length} candidates',
      );
    }
    if (collected.isEmpty) {
      debugPrint('[SCAN] Fallback empty, trying RAW signature scan');
      final rawCandidates = await _scanRawSignatures(
        rootPath,
        mode: mode,
        onProgress: onProgress,
      );
      collected.addAll(rawCandidates);
      debugPrint(
        '[SCAN] RAW signature scan found ${rawCandidates.length} candidates',
      );
    }

    collected.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    final totalBytes = collected.fold<int>(
      0,
      (acc, file) => acc + file.sizeBytes,
    );

    debugPrint(
      '[SCAN] Done visited=$visited collected=${collected.length} unreadable=$unreadableEntries skippedQuick=$skippedByQuickMode',
    );
    onProgress(1, 'Analyse finalisee');

    return ScanResult(
      files: collected,
      totalBytes: totalBytes,
      unreadableEntries: unreadableEntries,
      skippedByQuickMode: skippedByQuickMode,
      extensionCounts: buildExtensionCounts(collected),
    );
  }

  List<String> _readMountedDrivesFromWindows() {
    if (!Platform.isWindows) {
      return const [];
    }

    try {
      final result = Process.runSync('cmd', ['/c', 'fsutil fsinfo drives']);
      if (result.exitCode != 0) {
        return const [];
      }

      final text = result.stdout.toString();
      final matches = RegExp(
        r'([A-Z]:\\)',
        caseSensitive: false,
      ).allMatches(text);
      final paths = matches.map((m) => m.group(1)!.toUpperCase()).toList();
      return paths;
    } catch (_) {
      return const [];
    }
  }

  List<DriveEntry> _uniqueDrives(List<DriveEntry> drives) {
    final seen = <String>{};
    final unique = <DriveEntry>[];

    for (final drive in drives) {
      if (seen.add(drive.path.toUpperCase())) {
        unique.add(drive);
      }
    }
    return unique;
  }

  Future<RecoveryReport> recoverFiles({
    required String sourceRoot,
    required String destinationRoot,
    required List<RecoverableFile> files,
    required int workerCount,
    required List<RecoveryCategory> priorityOrder,
    required void Function(double progress, String status) onProgress,
  }) async {
    debugPrint(
      '[RECOVERY] Start source=$sourceRoot destination=$destinationRoot files=${files.length}',
    );
    final prioritizedFiles = _prioritizeFiles(files, priorityOrder);
    final total = prioritizedFiles.length;
    if (total == 0) {
      return RecoveryReport(
        copiedCount: 0,
        nonUsableCount: 0,
        failedCount: 0,
        destinationPath: destinationRoot,
      );
    }

    var copied = 0;
    var nonUsable = 0;
    var failed = 0;
    var processed = 0;
    final baseRawCandidates = _buildRawPathCandidates(sourceRoot);
    final queue = Queue<RecoverableFile>.from(prioritizedFiles);
    final workers = workerCount < 1 ? 1 : workerCount;

    Future<void> runWorker(int workerId) async {
      while (true) {
        if (queue.isEmpty) {
          return;
        }
        final file = queue.removeFirst();
        final source = File(file.fullPath);
        final stagingPath = _buildStagingPath(destinationRoot, file);
        final stagingFile = File(stagingPath);

        var success = false;
        try {
          await stagingFile.parent.create(recursive: true);
          if (file.isCarved &&
              file.carveStart != null &&
              file.carveEnd != null) {
            success = await _extractCarvedFile(
              sourceRoot,
              stagingPath,
              file.carveStart!,
              file.carveEnd!,
              preferredRawPath: file.rawSourcePath,
              baseRawCandidates: baseRawCandidates,
            );
            if (!success) {
              debugPrint(
                '[RECOVERY] Failed carve extract: ${file.relativePath}',
              );
            }
          } else {
            await source.copy(stagingPath);
            success = true;
          }
        } on FileSystemException {
          success = false;
          debugPrint('[RECOVERY] Failed copy: ${file.fullPath}');
        }

        if (success) {
          final usable = await _isRecoveredFileUsable(
            stagingPath,
            file.extension,
          );
          final classifiedPath = _buildClassifiedOutputPath(
            destinationRoot: destinationRoot,
            file: file,
            usable: usable,
          );
          final moved = await _moveFileToDestination(
            fromPath: stagingPath,
            toPath: classifiedPath,
          );
          if (moved) {
            if (usable) {
              copied += 1;
            } else {
              nonUsable += 1;
            }
          } else {
            failed += 1;
          }
        } else {
          failed += 1;
        }
        processed += 1;

        if (processed % 100 == 0 || processed == total) {
          debugPrint(
            '[RECOVERY] Worker $workerId progress $processed/$total '
            'ok=$copied non_usable=$nonUsable failed=$failed',
          );
        }
        onProgress(
          processed / total,
          'Recuperation ($workers workers): $processed/$total fichiers',
        );
      }
    }

    await Future.wait(List.generate(workers, (index) => runWorker(index + 1)));

    return RecoveryReport(
      copiedCount: copied,
      nonUsableCount: nonUsable,
      failedCount: failed,
      destinationPath: destinationRoot,
    );
  }

  List<RecoverableFile> _scanUsingWindowsDir(
    String rootPath, {
    required ScanMode mode,
  }) {
    if (!Platform.isWindows) {
      return const [];
    }

    try {
      final result = Process.runSync('cmd', [
        '/c',
        'dir',
        rootPath,
        '/s',
        '/b',
        '/a:-d',
      ]);
      if (result.exitCode != 0) {
        debugPrint(
          '[SCAN] Fallback dir command failed exit=${result.exitCode}',
        );
        return const [];
      }

      final output = result.stdout.toString();
      final lines = output
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      final maxFindings = _maxFindingsForMode(mode);
      final selected = maxFindings == null
          ? lines
          : lines.take(maxFindings).toList();

      final candidates = selected
          .map(
            (fullPath) => RecoverableFile(
              fullPath: fullPath,
              relativePath: _safeRelativePath(fullPath, rootPath),
              sizeBytes: 0,
              extension: fullPath.contains('.') ? fullPath.split('.').last : '',
              lastModified: DateTime.fromMillisecondsSinceEpoch(0),
            ),
          )
          .toList();

      return candidates;
    } catch (e) {
      debugPrint('[SCAN] Fallback exception: $e');
      return const [];
    }
  }

  Future<List<RecoverableFile>> _scanRawSignatures(
    String rootPath, {
    required ScanMode mode,
    required void Function(double progress, String status) onProgress,
  }) async {
    if (!Platform.isWindows) {
      return const [];
    }

    final rawCandidates = _buildRawPathCandidates(rootPath);
    if (rawCandidates.isEmpty) {
      debugPrint('[RAW] No usable raw path found for root "$rootPath"');
      return const [];
    }

    const chunkSize = 4 * 1024 * 1024;
    const overlap = 128 * 1024;
    final int? maxFindings = _maxFindingsForMode(mode);

    final jpegStart = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
    final jpegEnd = Uint8List.fromList([0xFF, 0xD9]);
    final pngStart = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ]);
    final pngEnd = Uint8List.fromList(ascii.encode('IEND'));
    final pdfStart = Uint8List.fromList(ascii.encode('%PDF-'));
    final pdfEnd = Uint8List.fromList(ascii.encode('%%EOF'));
    final riff = Uint8List.fromList(ascii.encode('RIFF'));
    final avi = Uint8List.fromList(ascii.encode('AVI '));
    final ftyp = Uint8List.fromList(ascii.encode('ftyp'));

    final globalResults = <RecoverableFile>[];
    onProgress(0.02, 'Analyse brute: preparation des sources disque...');

    for (
      var candidateIndex = 0;
      candidateIndex < rawCandidates.length;
      candidateIndex++
    ) {
      final rawPath = rawCandidates[candidateIndex];
      RandomAccessFile? raf;
      final localResults = <RecoverableFile>[];
      try {
        debugPrint('[RAW] Trying open path: $rawPath');
        onProgress(
          _rawProgress(
            candidateIndex: candidateIndex,
            candidateCount: rawCandidates.length,
            candidateRatio: 0,
          ),
          'Analyse brute: ouverture $rawPath',
        );
        raf = await File(rawPath).open(mode: FileMode.read);
        final length = await raf.length();
        debugPrint('[RAW] Opened $rawPath length=$length');

        var offset = 0;
        var chunkCounter = 0;
        final stopwatch = Stopwatch()..start();
        while (offset < length &&
            _canCollectMore(localResults.length, maxFindings)) {
          final toRead = (offset + chunkSize > length)
              ? (length - offset)
              : chunkSize;
          await raf.setPosition(offset);
          final bytes = await raf.read(toRead);
          if (bytes.isEmpty) {
            break;
          }

          _collectAviRiffSignatures(
            bytes: bytes,
            baseOffset: offset,
            riffPattern: riff,
            aviPattern: avi,
            container: localResults,
            maxFindings: maxFindings,
            rawSourcePath: rawPath,
          );
          _collectMp4FtypSignatures(
            bytes: bytes,
            baseOffset: offset,
            ftypPattern: ftyp,
            container: localResults,
            maxFindings: maxFindings,
            defaultSpanBytes: mode == ScanMode.rapide
                ? 32 * 1024 * 1024
                : 128 * 1024 * 1024,
            rawSourcePath: rawPath,
          );
          _collectSignatures(
            bytes: bytes,
            baseOffset: offset,
            startPattern: jpegStart,
            endPattern: jpegEnd,
            extension: 'jpg',
            container: localResults,
            maxFindings: maxFindings,
            rawSourcePath: rawPath,
          );
          _collectSignatures(
            bytes: bytes,
            baseOffset: offset,
            startPattern: pngStart,
            endPattern: pngEnd,
            extension: 'png',
            container: localResults,
            maxFindings: maxFindings,
            endExtraBytes: 8,
            rawSourcePath: rawPath,
          );
          _collectSignatures(
            bytes: bytes,
            baseOffset: offset,
            startPattern: pdfStart,
            endPattern: pdfEnd,
            extension: 'pdf',
            container: localResults,
            maxFindings: maxFindings,
            endExtraBytes: 5,
            rawSourcePath: rawPath,
          );

          offset += chunkSize - overlap;
          chunkCounter += 1;
          if (chunkCounter % 8 == 0 || offset >= length) {
            final eta = _estimateEta(
              elapsed: stopwatch.elapsed,
              current: offset,
              total: length,
            );
            final ratio = length <= 0
                ? 0
                : ((offset / length) * 100).clamp(0, 100);
            onProgress(
              _rawProgress(
                candidateIndex: candidateIndex,
                candidateCount: rawCandidates.length,
                candidateRatio: length <= 0 ? 0 : (offset / length).clamp(0, 1),
              ),
              'Analyse brute ${ratio.toStringAsFixed(1)}% | '
              '${localResults.length} signatures | ETA ${_formatDuration(eta)}',
            );
          }
        }

        debugPrint(
          '[RAW] Candidate "$rawPath" yielded ${localResults.length} signatures',
        );
        globalResults.addAll(localResults);
      } catch (e) {
        debugPrint('[RAW] Candidate failed "$rawPath": $e');
        final win32Results = await _scanRawCandidateWithWin32(
          rawPath,
          mode: mode,
          candidateIndex: candidateIndex,
          candidateCount: rawCandidates.length,
          onProgress: onProgress,
        );
        if (win32Results.isNotEmpty) {
          debugPrint(
            '[RAW] Win32 fallback yielded ${win32Results.length} signatures for $rawPath',
          );
          globalResults.addAll(win32Results);
        }
      } finally {
        await raf?.close();
      }
    }

    final unique = <String, RecoverableFile>{};
    for (final file in globalResults) {
      unique['${file.carveStart}-${file.carveEnd}-${file.extension}'] = file;
    }
    final deduped = unique.values.toList();
    onProgress(
      0.98,
      'Analyse brute terminee (${deduped.length} signatures dedupliquees).',
    );
    return deduped;
  }

  Future<List<RecoverableFile>> _scanRawCandidateWithWin32(
    String rawPath, {
    required ScanMode mode,
    required int candidateIndex,
    required int candidateCount,
    required void Function(double progress, String status) onProgress,
  }) async {
    final handle = _openWin32RawHandle(rawPath);
    if (handle == null) {
      return const [];
    }
    try {
      final length =
          _getWin32HandleLength(handle) ?? _fallbackRawLength(rawPath);
      if (length == null || length <= 0) {
        debugPrint('[RAW] Win32 length unavailable for $rawPath');
        return const [];
      }
      debugPrint('[RAW] Win32 opened $rawPath length=$length');

      const chunkSize = 4 * 1024 * 1024;
      const overlap = 128 * 1024;
      final int? maxFindings = _maxFindingsForMode(mode);
      final results = <RecoverableFile>[];
      final stopwatch = Stopwatch()..start();

      final jpegStart = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      final jpegEnd = Uint8List.fromList([0xFF, 0xD9]);
      final pngStart = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final pngEnd = Uint8List.fromList(ascii.encode('IEND'));
      final pdfStart = Uint8List.fromList(ascii.encode('%PDF-'));
      final pdfEnd = Uint8List.fromList(ascii.encode('%%EOF'));
      final riff = Uint8List.fromList(ascii.encode('RIFF'));
      final avi = Uint8List.fromList(ascii.encode('AVI '));
      final ftyp = Uint8List.fromList(ascii.encode('ftyp'));

      var offset = 0;
      var chunkCounter = 0;
      while (offset < length && _canCollectMore(results.length, maxFindings)) {
        final toRead = (offset + chunkSize > length)
            ? (length - offset)
            : chunkSize;
        final bytes = _readWin32Bytes(handle, offset, toRead);
        if (bytes == null || bytes.isEmpty) {
          break;
        }

        _collectAviRiffSignatures(
          bytes: bytes,
          baseOffset: offset,
          riffPattern: riff,
          aviPattern: avi,
          container: results,
          maxFindings: maxFindings,
          rawSourcePath: rawPath,
        );
        _collectMp4FtypSignatures(
          bytes: bytes,
          baseOffset: offset,
          ftypPattern: ftyp,
          container: results,
          maxFindings: maxFindings,
          defaultSpanBytes: mode == ScanMode.rapide
              ? 32 * 1024 * 1024
              : 128 * 1024 * 1024,
          rawSourcePath: rawPath,
        );
        _collectSignatures(
          bytes: bytes,
          baseOffset: offset,
          startPattern: jpegStart,
          endPattern: jpegEnd,
          extension: 'jpg',
          container: results,
          maxFindings: maxFindings,
          rawSourcePath: rawPath,
        );
        _collectSignatures(
          bytes: bytes,
          baseOffset: offset,
          startPattern: pngStart,
          endPattern: pngEnd,
          extension: 'png',
          container: results,
          maxFindings: maxFindings,
          endExtraBytes: 8,
          rawSourcePath: rawPath,
        );
        _collectSignatures(
          bytes: bytes,
          baseOffset: offset,
          startPattern: pdfStart,
          endPattern: pdfEnd,
          extension: 'pdf',
          container: results,
          maxFindings: maxFindings,
          endExtraBytes: 5,
          rawSourcePath: rawPath,
        );

        offset += chunkSize - overlap;
        chunkCounter += 1;
        if (chunkCounter % 8 == 0 || offset >= length) {
          final eta = _estimateEta(
            elapsed: stopwatch.elapsed,
            current: offset,
            total: length,
          );
          final ratio = length <= 0
              ? 0
              : ((offset / length) * 100).clamp(0, 100);
          onProgress(
            _rawProgress(
              candidateIndex: candidateIndex,
              candidateCount: candidateCount,
              candidateRatio: length <= 0 ? 0 : (offset / length).clamp(0, 1),
            ),
            'Analyse brute Win32 ${ratio.toStringAsFixed(1)}% | '
            '${results.length} signatures | ETA ${_formatDuration(eta)}',
          );
        }
        if (chunkCounter % 64 == 0 || offset >= length) {
          final ratio = length <= 0
              ? 0
              : ((offset / length) * 100).clamp(0, 100);
          debugPrint(
            '[RAW] Win32 progress ${ratio.toStringAsFixed(1)}% on $rawPath | signatures=${results.length} | elapsed=${stopwatch.elapsed.inSeconds}s',
          );
        }
      }

      return results;
    } finally {
      CloseHandle(handle);
    }
  }

  HANDLE? _openWin32RawHandle(String path) {
    final pPath = path.toNativeUtf16();
    try {
      final Win32Result(value: handle, :error) = CreateFile(
        PCWSTR(pPath),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
      );
      if (!handle.isValid || handle == INVALID_HANDLE_VALUE) {
        debugPrint('[RAW] Win32 CreateFile failed path="$path" err=$error');
        return null;
      }
      return handle;
    } finally {
      calloc.free(pPath);
    }
  }

  int? _getWin32HandleLength(HANDLE handle) {
    final sizePtr = calloc<Int64>();
    try {
      final Win32Result(value: ok, :error) = GetFileSizeEx(handle, sizePtr);
      if (!ok) {
        debugPrint('[RAW] Win32 GetFileSizeEx failed err=$error');
        return null;
      }
      final value = sizePtr.value;
      return value.toInt();
    } finally {
      calloc.free(sizePtr);
    }
  }

  int? _fallbackRawLength(String rawPath) {
    final physicalMatch = RegExp(
      r'PhysicalDrive(\d+)',
      caseSensitive: false,
    ).firstMatch(rawPath);
    if (physicalMatch != null) {
      final diskNumber = int.tryParse(physicalMatch.group(1) ?? '');
      if (diskNumber == null) {
        return null;
      }
      final size = _queryDiskSizeFromPowerShell(diskNumber);
      if (size != null) {
        debugPrint(
          '[RAW] Fallback disk size from Get-Disk($diskNumber): $size',
        );
      }
      return size;
    }
    return null;
  }

  int? _queryDiskSizeFromPowerShell(int diskNumber) {
    try {
      final result = Process.runSync('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '(Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue).Size',
      ]);
      if (result.exitCode != 0) {
        return null;
      }
      final value = int.tryParse(result.stdout.toString().trim());
      if (value == null || value <= 0) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  Uint8List? _readWin32Bytes(HANDLE handle, int offset, int length) {
    return _readWin32BytesInternal(
      handle,
      offset,
      length,
      allowAlignedRetry: true,
    );
  }

  Uint8List? _readWin32BytesInternal(
    HANDLE handle,
    int offset,
    int length, {
    required bool allowAlignedRetry,
  }) {
    final moveResult = calloc<Int64>();
    final outBytes = calloc<Uint8>(length);
    final readPtr = calloc<Uint32>();
    try {
      final Win32Result(value: moved, :error) = SetFilePointerEx(
        handle,
        offset,
        moveResult,
        FILE_BEGIN,
      );
      if (!moved) {
        debugPrint(
          '[RAW] Win32 SetFilePointerEx failed err=$error offset=$offset',
        );
        return null;
      }

      final Win32Result(value: ok, error: readErr) = ReadFile(
        handle,
        outBytes,
        length,
        readPtr,
        nullptr,
      );
      if (!ok) {
        if (allowAlignedRetry && readErr == ERROR_INVALID_PARAMETER) {
          final recovered = _readWin32BytesAlignedFallback(
            handle,
            offset,
            length,
          );
          if (recovered != null) {
            debugPrint(
              '[RAW] Win32 aligned fallback succeeded at offset=$offset length=$length',
            );
            return recovered;
          }
        }
        debugPrint('[RAW] Win32 ReadFile failed err=$readErr offset=$offset');
        return null;
      }

      final read = readPtr.value;
      if (read == 0) {
        return Uint8List(0);
      }
      return Uint8List.fromList(outBytes.asTypedList(read));
    } finally {
      calloc.free(moveResult);
      calloc.free(outBytes);
      calloc.free(readPtr);
    }
  }

  Uint8List? _readWin32BytesAlignedFallback(
    HANDLE handle,
    int offset,
    int length,
  ) {
    const sectorSize = 512;
    if (length <= 0) {
      return Uint8List(0);
    }

    final alignedOffset = offset - (offset % sectorSize);
    final shift = offset - alignedOffset;
    final wanted = length + shift;
    var alignedLength = ((wanted + sectorSize - 1) ~/ sectorSize) * sectorSize;
    if (alignedLength <= 0) {
      alignedLength = sectorSize;
    }

    final alignedBytes = _readWin32BytesInternal(
      handle,
      alignedOffset,
      alignedLength,
      allowAlignedRetry: false,
    );
    if (alignedBytes == null || alignedBytes.length <= shift) {
      return null;
    }
    final end = (shift + length) <= alignedBytes.length
        ? (shift + length)
        : alignedBytes.length;
    return Uint8List.fromList(alignedBytes.sublist(shift, end));
  }

  void _collectSignatures({
    required Uint8List bytes,
    required int baseOffset,
    required Uint8List startPattern,
    required Uint8List endPattern,
    required String extension,
    required List<RecoverableFile> container,
    required int? maxFindings,
    required String rawSourcePath,
    int endExtraBytes = 0,
  }) {
    var cursor = 0;
    while (cursor < bytes.length - startPattern.length &&
        _canCollectMore(container.length, maxFindings)) {
      final start = _indexOfPattern(bytes, startPattern, cursor);
      if (start < 0) {
        break;
      }
      if (extension == 'jpg' && !_looksLikeJpegHeader(bytes, start)) {
        cursor = start + startPattern.length;
        continue;
      }
      final end = _indexOfPattern(
        bytes,
        endPattern,
        start + startPattern.length,
      );
      if (end < 0) {
        cursor = start + startPattern.length;
        continue;
      }

      final carveStart = baseOffset + start;
      final carveEnd = baseOffset + end + endPattern.length + endExtraBytes;
      final size = carveEnd - carveStart;
      final minSize = _minCarvedSizeForExtension(extension);
      final maxSize = _maxCarvedSizeForExtension(extension);
      if (size >= minSize && size <= maxSize) {
        final name = 'RAW_${extension.toUpperCase()}_$carveStart.$extension';
        container.add(
          RecoverableFile(
            fullPath: '__RAW__',
            relativePath: 'recupere_brut\\$name',
            sizeBytes: size,
            extension: extension,
            lastModified: DateTime.fromMillisecondsSinceEpoch(0),
            isCarved: true,
            carveStart: carveStart,
            carveEnd: carveEnd,
            rawSourcePath: rawSourcePath,
          ),
        );
      }

      cursor = end + endPattern.length;
    }
  }

  void _collectAviRiffSignatures({
    required Uint8List bytes,
    required int baseOffset,
    required Uint8List riffPattern,
    required Uint8List aviPattern,
    required List<RecoverableFile> container,
    required int? maxFindings,
    required String rawSourcePath,
  }) {
    var cursor = 0;
    while (cursor < bytes.length - 16 &&
        _canCollectMore(container.length, maxFindings)) {
      final riffPos = _indexOfPattern(bytes, riffPattern, cursor);
      if (riffPos < 0) {
        break;
      }

      final aviTagPos = riffPos + 8;
      final looksLikeAvi =
          aviTagPos + aviPattern.length <= bytes.length &&
          bytes[aviTagPos] == aviPattern[0] &&
          bytes[aviTagPos + 1] == aviPattern[1] &&
          bytes[aviTagPos + 2] == aviPattern[2] &&
          bytes[aviTagPos + 3] == aviPattern[3];
      if (!looksLikeAvi) {
        cursor = riffPos + 4;
        continue;
      }

      final sizeField =
          bytes[riffPos + 4] |
          (bytes[riffPos + 5] << 8) |
          (bytes[riffPos + 6] << 16) |
          (bytes[riffPos + 7] << 24);
      final totalSize = sizeField + 8;
      if (totalSize <= 1024 || totalSize > 2 * 1024 * 1024 * 1024) {
        cursor = riffPos + 4;
        continue;
      }

      final carveStart = baseOffset + riffPos;
      final carveEnd = carveStart + totalSize;
      final name = 'RAW_AVI_$carveStart.avi';
      container.add(
        RecoverableFile(
          fullPath: '__RAW__',
          relativePath: 'recupere_brut\\$name',
          sizeBytes: totalSize,
          extension: 'avi',
          lastModified: DateTime.fromMillisecondsSinceEpoch(0),
          isCarved: true,
          carveStart: carveStart,
          carveEnd: carveEnd,
          rawSourcePath: rawSourcePath,
        ),
      );
      cursor = riffPos + 12;
    }
  }

  void _collectMp4FtypSignatures({
    required Uint8List bytes,
    required int baseOffset,
    required Uint8List ftypPattern,
    required List<RecoverableFile> container,
    required int? maxFindings,
    required int defaultSpanBytes,
    required String rawSourcePath,
  }) {
    var cursor = 0;
    while (cursor < bytes.length - 12 &&
        _canCollectMore(container.length, maxFindings)) {
      final ftypPos = _indexOfPattern(bytes, ftypPattern, cursor);
      if (ftypPos < 0) {
        break;
      }

      final start = ftypPos - 4;
      if (start < 0) {
        cursor = ftypPos + 4;
        continue;
      }

      final carveStart = baseOffset + start;
      final carveEnd = carveStart + defaultSpanBytes;
      final name = 'RAW_MP4_$carveStart.mp4';
      container.add(
        RecoverableFile(
          fullPath: '__RAW__',
          relativePath: 'recupere_brut\\$name',
          sizeBytes: defaultSpanBytes,
          extension: 'mp4',
          lastModified: DateTime.fromMillisecondsSinceEpoch(0),
          isCarved: true,
          carveStart: carveStart,
          carveEnd: carveEnd,
          rawSourcePath: rawSourcePath,
        ),
      );
      cursor = ftypPos + 4;
    }
  }

  int _indexOfPattern(Uint8List data, Uint8List pattern, int from) {
    if (pattern.isEmpty || from >= data.length) {
      return -1;
    }
    for (var i = from; i <= data.length - pattern.length; i++) {
      var same = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          same = false;
          break;
        }
      }
      if (same) {
        return i;
      }
    }
    return -1;
  }

  String _toRawVolumePath(String rootPath) {
    final match = RegExp(r'[A-Za-z]').firstMatch(rootPath);
    final letter = (match?.group(0) ?? 'C').toUpperCase();
    final rawPath = '\\\\.\\$letter:';
    debugPrint('[RAW] Computed raw volume path from "$rootPath" => "$rawPath"');
    return rawPath;
  }

  Future<bool> _extractCarvedFile(
    String sourceRoot,
    String destinationPath,
    int start,
    int end, {
    String? preferredRawPath,
    List<String>? baseRawCandidates,
  }) async {
    RandomAccessFile? input;
    RandomAccessFile? output;
    try {
      final rawCandidates =
          baseRawCandidates ?? _buildRawPathCandidates(sourceRoot);
      final physicalCandidates = rawCandidates
          .where(_isPhysicalDrivePath)
          .toList();
      final orderedCandidates = <String>[
        if (preferredRawPath != null && preferredRawPath.trim().isNotEmpty)
          preferredRawPath.trim(),
        if (physicalCandidates.isNotEmpty)
          ...physicalCandidates
        else
          ...rawCandidates,
      ];
      final dedup = <String>{};
      final finalCandidates = orderedCandidates
          .where((p) => dedup.add(p.toLowerCase()))
          .toList();
      final length = end - start;
      if (length <= 0) {
        return false;
      }

      Object? lastError;
      for (final rawPath in finalCandidates) {
        try {
          debugPrint('[RAW] Extract try source: $rawPath');
          input = await File(rawPath).open(mode: FileMode.read);
          output = await File(destinationPath).open(mode: FileMode.write);
          await input.setPosition(start);
          var remaining = length;
          const chunk = 512 * 1024;
          while (remaining > 0) {
            final toRead = remaining > chunk ? chunk : remaining;
            final bytes = await input.read(toRead);
            if (bytes.isEmpty) {
              break;
            }
            await output.writeFrom(bytes);
            remaining -= bytes.length;
          }
          if (remaining == 0) {
            if (_isJpegPath(destinationPath) &&
                !await _validateRecoveredJpeg(destinationPath)) {
              debugPrint('[RAW] JPEG validation failed for $destinationPath');
              try {
                await output.close();
                output = null;
                await File(destinationPath).delete();
              } catch (_) {}
              continue;
            }
            return true;
          }
          debugPrint(
            '[RAW] Dart extract incomplete for "$rawPath": remaining=$remaining',
          );
          try {
            await output.close();
            output = null;
            await File(destinationPath).delete();
          } catch (_) {}
        } catch (e) {
          lastError = e;
          input = null;
          final extracted = await _extractCarvedWithWin32(
            rawPath: rawPath,
            destinationPath: destinationPath,
            start: start,
            length: length,
          );
          if (extracted) {
            return true;
          }
        }
      }
      debugPrint('[RAW] extract open source failed: $lastError');
      return false;
    } catch (e) {
      debugPrint('[RAW] extract failed: $e');
      return false;
    } finally {
      await input?.close();
      await output?.close();
    }
  }

  Future<bool> _extractCarvedWithWin32({
    required String rawPath,
    required String destinationPath,
    required int start,
    required int length,
  }) async {
    final handle = _openWin32RawHandle(rawPath);
    if (handle == null) {
      return false;
    }
    RandomAccessFile? output;
    try {
      output = await File(destinationPath).open(mode: FileMode.write);
      var offset = start;
      var remaining = length;
      const chunk = 512 * 1024;
      while (remaining > 0) {
        final toRead = remaining > chunk ? chunk : remaining;
        final bytes = _readWin32Bytes(handle, offset, toRead);
        if (bytes == null || bytes.isEmpty) {
          break;
        }
        await output.writeFrom(bytes);
        offset += bytes.length;
        remaining -= bytes.length;
      }
      if (remaining == 0) {
        if (_isJpegPath(destinationPath) &&
            !await _validateRecoveredJpeg(destinationPath)) {
          debugPrint('[RAW] JPEG validation failed for $destinationPath');
          try {
            await output.close();
            output = null;
            await File(destinationPath).delete();
          } catch (_) {}
          return false;
        }
        return true;
      }
      debugPrint(
        '[RAW] Win32 extract incomplete for "$rawPath": remaining=$remaining',
      );
      try {
        await output.close();
        output = null;
        await File(destinationPath).delete();
      } catch (_) {}
      return false;
    } catch (e) {
      debugPrint('[RAW] extract win32 failed for "$rawPath": $e');
      return false;
    } finally {
      await output?.close();
      CloseHandle(handle);
    }
  }

  List<String> _buildRawPathCandidates(String rootPath) {
    final candidates = <String>[];
    final driveRaw = _toRawVolumePath(rootPath);
    candidates.add(driveRaw);

    final volumeGuid = _resolveVolumeGuidPath(rootPath);
    if (volumeGuid != null && volumeGuid.isNotEmpty) {
      candidates.add(volumeGuid);
      if (volumeGuid.endsWith(r'\')) {
        candidates.add(volumeGuid.substring(0, volumeGuid.length - 1));
      } else {
        candidates.add('$volumeGuid\\');
      }
    }

    final physicalDrive = _resolvePhysicalDrivePath(rootPath);
    if (physicalDrive != null && physicalDrive.isNotEmpty) {
      candidates.add(physicalDrive);
      debugPrint(
        '[RAW] Resolved physical drive for "$rootPath" => "$physicalDrive"',
      );
    }

    final unique = <String>{};
    return candidates.where((c) => unique.add(c.toLowerCase())).toList();
  }

  String? _resolveVolumeGuidPath(String rootPath) {
    if (!Platform.isWindows) {
      return null;
    }
    final normalized = rootPath.replaceAll('/', r'\').trim();
    if (normalized.isEmpty) {
      return null;
    }

    // Exemple: mountvol G: /L -> \\?\Volume{GUID}\
    final drive = normalized.endsWith(r'\')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    try {
      final result = Process.runSync('cmd', ['/c', 'mountvol', drive, '/L']);
      if (result.exitCode != 0) {
        return null;
      }
      final out = result.stdout.toString();
      final lines = out
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      final guidLine = lines.firstWhere(
        (l) => l.startsWith(r'\\?\Volume{'),
        orElse: () => '',
      );
      if (guidLine.isEmpty) {
        return null;
      }
      debugPrint('[RAW] Resolved volume GUID for "$rootPath" => "$guidLine"');
      return guidLine;
    } catch (e) {
      debugPrint('[RAW] resolve mountvol failed: $e');
      return null;
    }
  }

  String? _resolvePhysicalDrivePath(String rootPath) {
    if (!Platform.isWindows) {
      return null;
    }
    final match = RegExp(r'[A-Za-z]').firstMatch(rootPath);
    final letter = match?.group(0)?.toUpperCase();
    if (letter == null) {
      return null;
    }

    // Niveau le plus bas: map lettre -> DiskNumber -> \\.\PhysicalDriveN
    try {
      final psCommand =
          r"$p = Get-Partition -DriveLetter "
          '$letter'
          r" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DiskNumber; "
          r"if ($null -ne $p) { Write-Output $p }";
      final result = Process.runSync('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        psCommand,
      ]);
      if (result.exitCode == 0) {
        final out = result.stdout.toString().trim();
        final diskNumber = int.tryParse(out);
        if (diskNumber != null && diskNumber >= 0) {
          return r'\\.\PhysicalDrive'
              '$diskNumber';
        }
      }
    } catch (e) {
      debugPrint('[RAW] Resolve physical drive failed: $e');
    }

    return null;
  }

  String _safeRelativePath(String fullPath, String rootPath) {
    final normalizedRoot = rootPath.endsWith('\\')
        ? rootPath.substring(0, rootPath.length - 1)
        : rootPath;
    if (fullPath.startsWith(normalizedRoot)) {
      return fullPath
          .substring(normalizedRoot.length)
          .replaceFirst(RegExp(r'^[\\/]'), '');
    }
    return fullPath.split('\\').last;
  }

  List<RecoverableFile> _prioritizeFiles(
    List<RecoverableFile> files,
    List<RecoveryCategory> priorityOrder,
  ) {
    final orderMap = <RecoveryCategory, int>{};
    for (var i = 0; i < priorityOrder.length; i++) {
      orderMap[priorityOrder[i]] = i;
    }

    final sorted = [...files];
    sorted.sort((a, b) {
      final aCategory = _categorizeFile(a.extension);
      final bCategory = _categorizeFile(b.extension);
      final aRank = orderMap[aCategory] ?? 999;
      final bRank = orderMap[bCategory] ?? 999;
      if (aRank != bRank) {
        return aRank.compareTo(bRank);
      }
      return b.sizeBytes.compareTo(a.sizeBytes);
    });
    return sorted;
  }

  RecoveryCategory _categorizeFile(String extension) {
    final ext = extension.trim().toLowerCase();
    const video = {
      'mp4',
      'avi',
      'mov',
      'mkv',
      '3gp',
      'mts',
      'ts',
      'wmv',
      'm4v',
      'webm',
    };
    const image = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'bmp',
      'tif',
      'tiff',
      'webp',
      'heic',
      'raw',
      'nef',
      'cr2',
    };
    const document = {
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'txt',
      'rtf',
      'csv',
      'odt',
      'ods',
    };

    if (video.contains(ext)) {
      return RecoveryCategory.video;
    }
    if (image.contains(ext)) {
      return RecoveryCategory.image;
    }
    if (document.contains(ext)) {
      return RecoveryCategory.document;
    }
    return RecoveryCategory.other;
  }

  String _categoryFolderName(RecoveryCategory category) {
    switch (category) {
      case RecoveryCategory.video:
        return 'video';
      case RecoveryCategory.image:
        return 'img';
      case RecoveryCategory.document:
        return 'doc';
      case RecoveryCategory.other:
        return 'autres';
    }
  }

  String _buildStagingPath(String destinationRoot, RecoverableFile file) {
    final fileName = file.relativePath.split(RegExp(r'[\\/]')).last;
    final safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final fallbackExt = file.extension.trim().isEmpty
        ? ''
        : '.${file.extension.trim().toLowerCase()}';
    final ensuredName = safeName.contains('.')
        ? safeName
        : '$safeName$fallbackExt';
    final id = file.isCarved
        ? '${file.carveStart ?? 0}'
        : '${file.fullPath.hashCode.abs()}';
    return '$destinationRoot\\_staging\\${id}_$ensuredName';
  }

  String _buildClassifiedOutputPath({
    required String destinationRoot,
    required RecoverableFile file,
    required bool usable,
  }) {
    final category = _categorizeFile(file.extension);
    final categoryFolder = _categoryFolderName(category);
    final qualityFolder = usable ? 'exploitable' : 'non_exploitable';
    final fileName = file.relativePath.split(RegExp(r'[\\/]')).last;
    final safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final fallbackExt = file.extension.trim().isEmpty
        ? ''
        : '.${file.extension.trim().toLowerCase()}';
    final ensuredName = safeName.contains('.')
        ? safeName
        : '$safeName$fallbackExt';
    final id = file.isCarved
        ? '${file.carveStart ?? 0}'
        : '${file.fullPath.hashCode.abs()}';
    return '$destinationRoot\\$categoryFolder\\$qualityFolder\\${id}_$ensuredName';
  }

  Future<bool> _moveFileToDestination({
    required String fromPath,
    required String toPath,
  }) async {
    final source = File(fromPath);
    if (!await source.exists()) {
      return false;
    }
    final target = File(toPath);
    try {
      await target.parent.create(recursive: true);
      await source.rename(toPath);
      return true;
    } on FileSystemException {
      try {
        await source.copy(toPath);
        await source.delete();
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> _isRecoveredFileUsable(String path, String extension) async {
    final ext = extension.trim().toLowerCase();
    if (ext == 'jpg' || ext == 'jpeg') {
      return _validateRecoveredJpeg(path);
    }
    if (ext == 'png') {
      return _validateRecoveredPng(path);
    }
    if (ext == 'pdf') {
      return _validateRecoveredPdf(path);
    }
    if (ext == 'avi') {
      return _validateRecoveredAvi(path);
    }
    if (ext == 'mp4' || ext == 'mov' || ext == 'm4v' || ext == '3gp') {
      return _validateRecoveredMp4Like(path);
    }
    return true;
  }

  bool _canCollectMore(int currentLength, int? maxFindings) {
    if (maxFindings == null) {
      return true;
    }
    return currentLength < maxFindings;
  }

  int? _maxFindingsForMode(ScanMode mode) {
    switch (mode) {
      case ScanMode.rapide:
        return 10000;
      case ScanMode.intermediaire:
        return 100000;
      case ScanMode.complete:
        return null;
    }
  }

  String _scanModeLabel(ScanMode mode) {
    switch (mode) {
      case ScanMode.rapide:
        return 'rapide';
      case ScanMode.intermediaire:
        return 'intermediaire';
      case ScanMode.complete:
        return 'complete';
    }
  }

  Duration? _estimateEta({
    required Duration elapsed,
    required int current,
    required int total,
  }) {
    if (current <= 0 || total <= 0 || elapsed.inMilliseconds <= 0) {
      return null;
    }
    final remaining = total - current;
    if (remaining <= 0) {
      return Duration.zero;
    }
    final bytesPerMs = current / elapsed.inMilliseconds;
    if (bytesPerMs <= 0) {
      return null;
    }
    final ms = (remaining / bytesPerMs).round();
    if (ms < 0) {
      return null;
    }
    return Duration(milliseconds: ms);
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) {
      return '--:--';
    }
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  bool _isPhysicalDrivePath(String path) {
    return path.toLowerCase().contains('physicaldrive');
  }

  int _minCarvedSizeForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 8 * 1024;
      case 'png':
      case 'pdf':
        return 1024;
      default:
        return 256;
    }
  }

  int _maxCarvedSizeForExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 100 * 1024 * 1024;
      default:
        return 500 * 1024 * 1024;
    }
  }

  bool _looksLikeJpegHeader(Uint8List bytes, int start) {
    if (start + 4 >= bytes.length) {
      return false;
    }
    if (bytes[start] != 0xFF ||
        bytes[start + 1] != 0xD8 ||
        bytes[start + 2] != 0xFF) {
      return false;
    }
    final marker = bytes[start + 3];
    const allowedMarkers = <int>{
      0xE0,
      0xE1,
      0xE2,
      0xE3,
      0xE8,
      0xED,
      0xEE,
      0xDB,
      0xC0,
      0xC2,
    };
    return allowedMarkers.contains(marker);
  }

  bool _isJpegPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') || lower.endsWith('.jpeg');
  }

  Future<bool> _validateRecoveredJpeg(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 8 * 1024) {
        return false;
      }

      final raf = await file.open(mode: FileMode.read);
      try {
        final headLen = length < 65536 ? length : 65536;
        final head = await raf.read(headLen);
        if (head.length < 4) {
          return false;
        }
        if (head[0] != 0xFF || head[1] != 0xD8 || head[2] != 0xFF) {
          return false;
        }
        var hasSof = false;
        for (var i = 0; i < head.length - 1; i++) {
          if (head[i] == 0xFF && (head[i + 1] == 0xC0 || head[i + 1] == 0xC2)) {
            hasSof = true;
            break;
          }
        }
        if (!hasSof) {
          return false;
        }

        final tailLen = length < 4096 ? length : 4096;
        await raf.setPosition(length - tailLen);
        final tail = await raf.read(tailLen);
        for (var i = 0; i < tail.length - 1; i++) {
          if (tail[i] == 0xFF && tail[i + 1] == 0xD9) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _validateRecoveredPng(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 64) {
        return false;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(16);
        final signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        for (var i = 0; i < signature.length; i++) {
          if (i >= head.length || head[i] != signature[i]) {
            return false;
          }
        }
        final tailLen = length < 2048 ? length : 2048;
        await raf.setPosition(length - tailLen);
        final tail = await raf.read(tailLen);
        final marker = ascii.encode('IEND');
        for (var i = 0; i <= tail.length - marker.length; i++) {
          if (tail[i] == marker[0] &&
              tail[i + 1] == marker[1] &&
              tail[i + 2] == marker[2] &&
              tail[i + 3] == marker[3]) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _validateRecoveredPdf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 64) {
        return false;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(8);
        final pdf = ascii.encode('%PDF-');
        for (var i = 0; i < pdf.length; i++) {
          if (i >= head.length || head[i] != pdf[i]) {
            return false;
          }
        }
        final tailLen = length < 4096 ? length : 4096;
        await raf.setPosition(length - tailLen);
        final tail = await raf.read(tailLen);
        final eof = ascii.encode('%%EOF');
        for (var i = 0; i <= tail.length - eof.length; i++) {
          if (tail[i] == eof[0] &&
              tail[i + 1] == eof[1] &&
              tail[i + 2] == eof[2] &&
              tail[i + 3] == eof[3] &&
              tail[i + 4] == eof[4]) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _validateRecoveredAvi(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 16) {
        return false;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(16);
        if (head.length < 12) {
          return false;
        }
        return head[0] == 0x52 &&
            head[1] == 0x49 &&
            head[2] == 0x46 &&
            head[3] == 0x46 &&
            head[8] == 0x41 &&
            head[9] == 0x56 &&
            head[10] == 0x49 &&
            head[11] == 0x20;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _validateRecoveredMp4Like(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return false;
      }
      final length = await file.length();
      if (length < 16) {
        return false;
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        final headLen = length < 4096 ? length : 4096;
        final head = await raf.read(headLen);
        final ftyp = ascii.encode('ftyp');
        for (var i = 0; i <= head.length - ftyp.length; i++) {
          if (head[i] == ftyp[0] &&
              head[i + 1] == ftyp[1] &&
              head[i + 2] == ftyp[2] &&
              head[i + 3] == ftyp[3]) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  double _rawProgress({
    required int candidateIndex,
    required int candidateCount,
    required double candidateRatio,
  }) {
    final totalCandidates = candidateCount <= 0 ? 1 : candidateCount;
    final base = candidateIndex / totalCandidates;
    final distributed = base + (candidateRatio / totalCandidates);
    return (0.05 + (distributed * 0.9)).clamp(0.05, 0.98);
  }
}
