import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pocket_extract/data/services/external_recovery_service.dart';
import 'package:pocket_extract/data/services/recovery_service.dart';
import 'package:pocket_extract/domain/enums/recovery_category.dart';
import 'package:pocket_extract/domain/enums/scan_mode.dart';
import 'package:pocket_extract/domain/models/drive_entry.dart';
import 'package:pocket_extract/domain/models/external_engine_status.dart';
import 'package:pocket_extract/domain/models/scan_result.dart';

class PocketExtractHomePage extends StatefulWidget {
  const PocketExtractHomePage({super.key});

  @override
  State<PocketExtractHomePage> createState() => _PocketExtractHomePageState();
}

class _PocketExtractHomePageState extends State<PocketExtractHomePage> {
  final _service = RecoveryService();
  final _externalService = ExternalRecoveryService();
  final _dateFormatter = DateFormat('dd/MM/yyyy HH:mm');
  final _folderNameController = TextEditingController(
    text: 'PocketExtract_Recuperation',
  );

  List<DriveEntry> _drives = [];
  DriveEntry? _selectedDrive;
  DriveEntry? _selectedDestinationDrive;
  ScanMode _scanMode = ScanMode.complete;
  ScanResult? _scanResult;
  String? _destinationPathPreview;
  String _status = 'Pret pour une analyse.';
  bool _isScanning = false;
  bool _isRecovering = false;
  bool _isInspectingExternal = false;
  bool _isLaunchingExternal = false;
  double _progress = 0;
  ExternalEngineStatus? _externalStatus;
  int _workerCount = 4;
  final List<RecoveryCategory> _priorityOrder = [
    RecoveryCategory.video,
    RecoveryCategory.image,
    RecoveryCategory.document,
    RecoveryCategory.other,
  ];

  @override
  void initState() {
    super.initState();
    _drives = _service.getAvailableDrives();
    if (_drives.isNotEmpty) {
      _selectedDrive = _drives.first;
      _selectedDestinationDrive = _drives.length > 1
          ? _drives[1]
          : _drives.first;
      _destinationPathPreview = _buildDestinationPath(
        _selectedDestinationDrive,
      );
    }
  }

  @override
  void dispose() {
    _folderNameController.dispose();
    super.dispose();
  }

  Future<void> _refreshDrives() async {
    setState(() {
      _drives = _service.getAvailableDrives();
      _selectedDrive = _drives.isEmpty ? null : _drives.first;
      _selectedDestinationDrive = _drives.isEmpty ? null : _drives.first;
      _destinationPathPreview = _buildDestinationPath(
        _selectedDestinationDrive,
      );
      _status = _drives.isEmpty
          ? 'Aucun lecteur detecte.'
          : 'Lecteurs mis a jour.';
    });
  }

  Future<void> _refreshExternalEnvironment() async {
    setState(() {
      _isInspectingExternal = true;
    });

    final status = await _externalService.inspectEnvironment();
    if (!mounted) {
      return;
    }
    setState(() {
      _externalStatus = status;
      _isInspectingExternal = false;
      _status =
          'Moteur pro: ${status.isAdmin ? "admin OK" : "non admin"} | '
          'PhotoRec: ${status.photoRecPath != null ? "detecte" : "absent"} | '
          'TestDisk: ${status.testDiskPath != null ? "detecte" : "absent"}';
    });
  }

  Future<void> _launchPhotoRecExternal() async {
    final external = _externalStatus;
    if (external == null || external.photoRecPath == null) {
      setState(() {
        _status =
            'PhotoRec introuvable. Place photorec_win.exe dans tools\\testdisk\\';
      });
      return;
    }
    if (!external.isAdmin) {
      setState(() {
        _status = 'Lance PocketExtract depuis un terminal Administrateur.';
      });
      return;
    }

    final destination = _destinationPathPreview;
    final source = _selectedDrive?.path;
    final args = <String>['/log'];
    if (destination != null && destination.isNotEmpty) {
      args.addAll(['/d', destination]);
    }
    if (source != null && source.isNotEmpty) {
      args.add(source);
    }

    setState(() {
      _isLaunchingExternal = true;
      _status = 'Lancement PhotoRec...';
    });
    final ok = await _externalService.launchTool(
      executablePath: external.photoRecPath!,
      args: args,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLaunchingExternal = false;
      _status = ok
          ? 'PhotoRec lance. Termine la recuperation puis clique "Importer recup_dir".'
          : 'Echec lancement PhotoRec.';
    });
  }

  Future<void> _launchTestDiskExternal() async {
    final external = _externalStatus;
    if (external == null || external.testDiskPath == null) {
      setState(() {
        _status =
            'TestDisk introuvable. Place testdisk_win.exe dans tools\\testdisk\\';
      });
      return;
    }
    if (!external.isAdmin) {
      setState(() {
        _status = 'Lance PocketExtract depuis un terminal Administrateur.';
      });
      return;
    }

    setState(() {
      _isLaunchingExternal = true;
      _status = 'Lancement TestDisk...';
    });
    final ok = await _externalService.launchTool(
      executablePath: external.testDiskPath!,
      args: const ['/log'],
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLaunchingExternal = false;
      _status = ok
          ? 'TestDisk lance. Repare la partition puis reviens sur PocketExtract.'
          : 'Echec lancement TestDisk.';
    });
  }

  Future<void> _importPhotoRecResults() async {
    final destination = _destinationPathPreview;
    if (destination == null || destination.isEmpty) {
      setState(() {
        _status =
            'Choisis un disque/dossier destination pour importer recup_dir.';
      });
      return;
    }

    setState(() {
      _isLaunchingExternal = true;
      _status = 'Import des recup_dir en cours...';
    });
    final result = await _externalService.importRecoveredFiles(destination);
    if (!mounted) {
      return;
    }
    setState(() {
      _isLaunchingExternal = false;
      _scanResult = result;
      _status =
          'Import termine: ${result.files.length} fichiers detectes dans recup_dir.';
    });
  }

  Future<void> _runScan() async {
    final source = _selectedDrive;
    if (source == null) {
      setState(() => _status = 'Selectionne un lecteur a analyser.');
      return;
    }

    setState(() {
      _isScanning = true;
      _scanResult = null;
      _progress = 0;
      _status =
          'Analyse ${_scanModeLabel(_scanMode)} en cours de ${source.path}...';
    });

    final result = await _service.scanForRecoverableFiles(
      source.path,
      mode: _scanMode,
      onProgress: (value, status) {
        if (!mounted) {
          return;
        }
        setState(() {
          _progress = value;
          _status = status;
        });
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isScanning = false;
      _scanResult = result;
      _progress = 1;
      final extensionSummary = _formatExtensionSummary(result.extensionCounts);
      _status = extensionSummary.isEmpty
          ? 'Analyse terminee: ${result.files.length} fichiers lisibles.'
          : 'Analyse terminee: ${result.files.length} fichiers lisibles | $extensionSummary';
    });
  }

  Future<void> _runRecovery() async {
    final source = _selectedDrive;
    final destinationDrive = _selectedDestinationDrive;
    final scan = _scanResult;
    final destination = _buildDestinationPath(destinationDrive);

    if (source == null || destinationDrive == null || scan == null) {
      setState(() {
        _status =
            'Selectionne un lecteur source, une analyse et un disque de destination.';
      });
      return;
    }
    if (destination == null) {
      setState(() {
        _status = 'Impossible de determiner le chemin de destination.';
      });
      return;
    }

    setState(() {
      _isRecovering = true;
      _progress = 0;
      _destinationPathPreview = destination;
      _status = 'Recuperation vers $destination...';
    });

    final report = await _service.recoverFiles(
      sourceRoot: source.path,
      destinationRoot: destination,
      files: scan.files,
      workerCount: _workerCount,
      priorityOrder: _priorityOrder,
      onProgress: (value, status) {
        if (!mounted) {
          return;
        }
        setState(() {
          _progress = value;
          _status = status;
        });
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecovering = false;
      _progress = 1;
      _status =
          'Termine: ${report.copiedCount} exploitables, '
          '${report.nonUsableCount} non exploitables, '
          '${report.failedCount} echecs.';
    });

    if (!context.mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rapport de recuperation'),
        content: Text(
          'Fichiers exploitables: ${report.copiedCount}\n'
          'Fichiers non exploitables: ${report.nonUsableCount}\n'
          'Echecs: ${report.failedCount}\n'
          'Destination: ${report.destinationPath}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  Future<void> _runScanAndRecovery() async {
    final destinationDrive = _selectedDestinationDrive;
    if (destinationDrive == null) {
      setState(() {
        _status =
            'Selectionne un disque de destination avant le mode automatique.';
      });
      return;
    }

    await _runScan();
    if (!mounted) {
      return;
    }

    final result = _scanResult;
    if (result == null || result.files.isEmpty) {
      setState(() {
        _status =
            'Analyse terminee sans fichier recuperable. Recuperation automatique annulee.';
      });
      return;
    }

    await _runRecovery();
  }

  @override
  Widget build(BuildContext context) {
    final canRunScan = !_isScanning && !_isRecovering && _selectedDrive != null;
    final canRunRecovery =
        !_isScanning &&
        !_isRecovering &&
        _selectedDestinationDrive != null &&
        _scanResult != null &&
        _scanResult!.files.isNotEmpty;
    final canRunScanAndRecovery =
        !_isScanning &&
        !_isRecovering &&
        _selectedDrive != null &&
        _selectedDestinationDrive != null;

    return Scaffold(
      appBar: AppBar(title: const Text('PocketExtract')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Lecteur source:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<DriveEntry>(
                    key: ValueKey('source-${_selectedDrive?.path ?? "none"}'),
                    initialValue: _selectedDrive,
                    isExpanded: true,
                    items: _drives
                        .map(
                          (drive) => DropdownMenuItem<DriveEntry>(
                            value: drive,
                            child: Text(
                              '${drive.path} - ${drive.label}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (_isScanning || _isRecovering)
                        ? null
                        : (value) => setState(() => _selectedDrive = value),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: (_isScanning || _isRecovering)
                      ? null
                      : _refreshDrives,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Actualiser'),
                ),
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<ScanMode>(
                    key: ValueKey('scanmode-${_scanMode.name}'),
                    initialValue: _scanMode,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: ScanMode.rapide,
                        child: Text('Analyse rapide'),
                      ),
                      DropdownMenuItem(
                        value: ScanMode.intermediaire,
                        child: Text('Analyse intermediaire (100k)'),
                      ),
                      DropdownMenuItem(
                        value: ScanMode.complete,
                        child: Text('Analyse complete'),
                      ),
                    ],
                    onChanged: (_isScanning || _isRecovering)
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => _scanMode = value);
                          },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: canRunScan ? _runScan : null,
                  icon: const Icon(Icons.search),
                  label: const Text('Analyser'),
                ),
                FilledButton.icon(
                  onPressed: canRunScanAndRecovery ? _runScanAndRecovery : null,
                  icon: const Icon(Icons.auto_mode),
                  label: const Text('Analyser + Recuperer'),
                ),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<DriveEntry>(
                    key: ValueKey(
                      'destination-${_selectedDestinationDrive?.path ?? "none"}',
                    ),
                    initialValue: _selectedDestinationDrive,
                    isExpanded: true,
                    items: _drives
                        .map(
                          (drive) => DropdownMenuItem<DriveEntry>(
                            value: drive,
                            child: Text(
                              '${drive.path} - ${drive.label}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (_isScanning || _isRecovering)
                        ? null
                        : (value) {
                            setState(() {
                              _selectedDestinationDrive = value;
                              _destinationPathPreview = _buildDestinationPath(
                                value,
                              );
                            });
                          },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Disque destination',
                    ),
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _folderNameController,
                    enabled: !_isScanning && !_isRecovering,
                    onChanged: (_) {
                      setState(() {
                        _destinationPathPreview = _buildDestinationPath(
                          _selectedDestinationDrive,
                        );
                      });
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Dossier de sauvegarde',
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: canRunRecovery ? _runRecovery : null,
                  icon: const Icon(Icons.file_download),
                  label: const Text('Recuperer'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildRecoveryStrategyPanel(),
            const SizedBox(height: 14),
            _buildExternalEnginePanel(),
            const SizedBox(height: 18),
            LinearProgressIndicator(
              value: (_isScanning || _isRecovering) ? _progress : null,
            ),
            const SizedBox(height: 10),
            Text(_status),
            const SizedBox(height: 8),
            Text('Destination: ${_destinationPathPreview ?? "non definie"}'),
            const SizedBox(height: 22),
            SizedBox(
              height: 420,
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: _buildResultPanel(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultPanel() {
    final result = _scanResult;
    if (result == null) {
      return const Center(
        child: Text(
          'Lance une analyse pour afficher les fichiers recuperables.',
        ),
      );
    }

    if (result.files.isEmpty) {
      return const Center(
        child: Text(
          'Aucun fichier lisible detecte sur le lecteur selectionne.',
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text(
            '${result.files.length} fichiers lisibles | '
            '${_formatBytes(result.totalBytes)} | '
            '${result.unreadableEntries} elements illisibles'
            '${result.skippedByQuickMode > 0 ? " | ${result.skippedByQuickMode} ignores en mode rapide" : ""}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (result.extensionCounts.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Text(
              'Par extension: ${_formatExtensionSummary(result.extensionCounts)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        Expanded(
          child: ListView.separated(
            itemCount: result.files.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final file = result.files[index];
              return ListTile(
                dense: true,
                title: Text(file.relativePath),
                subtitle: Text(
                  '${_formatBytes(file.sizeBytes)} | ${_dateFormatter.format(file.lastModified)}',
                ),
                trailing: _buildTypeBadge(file.extension),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTypeBadge(String extension) {
    final ext = extension.isEmpty ? 'AUTRE' : extension.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        ext,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildRecoveryStrategyPanel() {
    final isBusy = _isLaunchingExternal || _isScanning || _isRecovering;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Strategie de recuperation',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Workers paralleles:'),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<int>(
                    initialValue: _workerCount,
                    items: const [1, 2, 4, 6, 8]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value'),
                          ),
                        )
                        .toList(),
                    onChanged: isBusy
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => _workerCount = value);
                          },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Text(
                  'Ordre priorite: ${_priorityOrder.map(_categoryLabel).join(" > ")}',
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(_priorityOrder.length, (index) {
                final category = _priorityOrder[index];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_categoryLabel(category)),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: (isBusy || index == 0)
                            ? null
                            : () {
                                setState(() {
                                  final temp = _priorityOrder[index - 1];
                                  _priorityOrder[index - 1] =
                                      _priorityOrder[index];
                                  _priorityOrder[index] = temp;
                                });
                              },
                        icon: const Icon(Icons.arrow_back, size: 18),
                        constraints: const BoxConstraints.tightFor(
                          width: 26,
                          height: 26,
                        ),
                        padding: EdgeInsets.zero,
                        tooltip: 'Monter priorite',
                      ),
                      IconButton(
                        onPressed:
                            (isBusy || index == _priorityOrder.length - 1)
                            ? null
                            : () {
                                setState(() {
                                  final temp = _priorityOrder[index + 1];
                                  _priorityOrder[index + 1] =
                                      _priorityOrder[index];
                                  _priorityOrder[index] = temp;
                                });
                              },
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        constraints: const BoxConstraints.tightFor(
                          width: 26,
                          height: 26,
                        ),
                        padding: EdgeInsets.zero,
                        tooltip: 'Baisser priorite',
                      ),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExternalEnginePanel() {
    final external = _externalStatus;
    final isBusy = _isLaunchingExternal || _isScanning || _isRecovering;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Moteur Pro (PhotoRec/TestDisk)',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              external == null
                  ? 'Verification en cours...'
                  : 'Admin: ${external.isAdmin ? "oui" : "non"} | '
                        'PhotoRec: ${external.photoRecPath ?? "non detecte"} | '
                        'TestDisk: ${external.testDiskPath ?? "non detecte"}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: (_isInspectingExternal || isBusy)
                      ? null
                      : _refreshExternalEnvironment,
                  icon: const Icon(Icons.rule_folder),
                  label: const Text('Verifier environnement'),
                ),
                FilledButton.tonalIcon(
                  onPressed: isBusy ? null : _launchPhotoRecExternal,
                  icon: const Icon(Icons.movie_filter),
                  label: const Text('Lancer PhotoRec'),
                ),
                FilledButton.tonalIcon(
                  onPressed: isBusy ? null : _launchTestDiskExternal,
                  icon: const Icon(Icons.developer_board),
                  label: const Text('Lancer TestDisk'),
                ),
                FilledButton.icon(
                  onPressed: isBusy ? null : _importPhotoRecResults,
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('Importer recup_dir'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    }
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
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

  String _categoryLabel(RecoveryCategory category) {
    switch (category) {
      case RecoveryCategory.video:
        return 'Video';
      case RecoveryCategory.image:
        return 'Image';
      case RecoveryCategory.document:
        return 'Document';
      case RecoveryCategory.other:
        return 'Autres';
    }
  }

  String _formatExtensionSummary(Map<String, int> extensionCounts) {
    if (extensionCounts.isEmpty) {
      return '';
    }
    final entries = extensionCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(8)
        .map((e) => '${e.key.toUpperCase()}: ${e.value}')
        .join(' | ');
  }

  String? _buildDestinationPath(DriveEntry? drive) {
    if (drive == null) {
      return null;
    }
    final folderName = _folderNameController.text.trim().isEmpty
        ? 'PocketExtract_Recuperation'
        : _folderNameController.text.trim();
    return '${drive.path}$folderName';
  }
}
