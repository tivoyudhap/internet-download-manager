import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/download_task.dart';
import 'services/browser_bridge_server.dart';
import 'services/download_directory_picker.dart';
import 'services/download_queue_controller.dart';
import 'services/download_queue_store.dart';

const _ink = Color(0xFF172B4D);
const _muted = Color(0xFF718096);
const _blue = Color(0xFF1769AA);
const _canvas = Color(0xFFF4F7FB);

void main() => runApp(const DownloadManagerApp());

class DownloadManagerApp extends StatelessWidget {
  const DownloadManagerApp({
    super.key,
    this.queueController,
    this.settingsStore,
    this.directoryPicker,
  });

  final DownloadQueueController? queueController;
  final DownloadQueueStore? settingsStore;
  final DownloadDirectoryPicker? directoryPicker;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Internet Download Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: _blue),
        fontFamily: 'Arial',
      ),
      home: DownloadsPage(
        queueController: queueController,
        settingsStore: settingsStore,
        directoryPicker: directoryPicker,
      ),
    );
  }
}

class _Category {
  const _Category(this.label, this.icon, this.status);

  final String label;
  final IconData icon;
  final DownloadStatus? status;
}

enum _DownloadListOption { clearHistory }

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    this.queueController,
    this.settingsStore,
    this.directoryPicker,
  });

  final DownloadQueueController? queueController;
  final DownloadQueueStore? settingsStore;
  final DownloadDirectoryPicker? directoryPicker;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final DownloadQueueController _queue;
  DownloadQueueStore? _queueStore;
  late final DownloadDirectoryPicker _directoryPicker;
  BrowserBridgeServer? _browserBridge;
  final _searchController = TextEditingController();
  String? _downloadDirectory;
  bool _settingsOpen = false;
  bool _isUpdatingDirectory = false;

  static const _categories = <_Category>[
    _Category('All downloads', Icons.inbox_rounded, null),
    _Category(
      'In progress',
      Icons.downloading_rounded,
      DownloadStatus.downloading,
    ),
    _Category(
      'Completed',
      Icons.check_circle_outline_rounded,
      DownloadStatus.completed,
    ),
    _Category('Queue', Icons.schedule_rounded, DownloadStatus.queued),
  ];

  int _selectedCategory = 0;
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    _queueStore = widget.settingsStore ?? DownloadQueueStore();
    _directoryPicker =
        widget.directoryPicker ?? const DownloadDirectoryPicker();
    unawaited(_loadDownloadDirectory());
    if (widget.queueController == null) {
      _queue = DownloadQueueController(_queueStore!);
      unawaited(_startBrowserBridge());
    } else {
      _queue = widget.queueController!;
    }
    _queue.load();
  }

  Future<void> _loadDownloadDirectory() async {
    final store = _queueStore!;
    final directory =
        await store.configuredDownloadDirectory() ??
        await store.defaultDownloadDirectory();
    if (mounted) setState(() => _downloadDirectory = directory);
  }

  Future<void> _chooseDownloadDirectory() async {
    setState(() => _isUpdatingDirectory = true);
    try {
      final directory = await _directoryPicker.pickDirectory();
      if (directory == null) return;
      await _queueStore!.saveDownloadDirectory(directory);
      if (mounted) setState(() => _downloadDirectory = directory);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not select folder: ${error.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingDirectory = false);
    }
  }

  Future<void> _resetDownloadDirectory() async {
    setState(() => _isUpdatingDirectory = true);
    try {
      await _directoryPicker.clearAccess();
      await _queueStore!.saveDownloadDirectory(null);
      final directory = await _queueStore!.defaultDownloadDirectory();
      if (mounted) setState(() => _downloadDirectory = directory);
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reset folder: ${error.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingDirectory = false);
    }
  }

  Future<void> _confirmClearHistory() async {
    final historyCount = _queue.tasks
        .where(
          (task) =>
              task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed ||
              task.status == DownloadStatus.canceled,
        )
        .length;
    if (historyCount == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all history?'),
        content: Text(
          'Remove $historyCount completed, failed, or canceled downloads from '
          'the list? Downloaded files stay in their folders, and active or '
          'queued downloads are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _queue.clearHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Download history cleared.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear history: $error')),
      );
    }
  }

  Future<void> _clearTaskHistory(DownloadTask task) async {
    try {
      await _queue.removeHistoryItem(task.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Removed from download history.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear history: $error')),
      );
    }
  }

  Future<void> _confirmDeleteDownloadedFile(DownloadTask task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete downloaded file?'),
        content: Text(
          'Permanently delete "${task.fileName}" from '
          '${task.destinationDirectory} and remove it from history?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _queue.deleteDownloadedFile(task.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File deleted and removed from history.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete file: $error')));
    }
  }

  Future<void> _startBrowserBridge() async {
    try {
      final tokenFile = await _queueStore!.browserBridgeTokenFile();
      await tokenFile.parent.create(recursive: true);
      final random = Random.secure();
      final token = List<int>.generate(
        32,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      await tokenFile.writeAsString(token, flush: true);
      final bridge = await BrowserBridgeServer.start(
        token: token,
        onDownloadRequest: (request) async {
          await _queue.addUrl(
            request.url,
            isStream: request.isStream,
            suggestedFileName: request.suggestedFileName,
            requestHeaders: request.headers,
          );
          unawaited(_queue.processQueue());
        },
      );
      if (!mounted) {
        await bridge.close();
      } else {
        _browserBridge = bridge;
      }
    } catch (error) {
      debugPrint('Browser bridge could not start: $error');
    }
  }

  @override
  void dispose() {
    final bridge = _browserBridge;
    if (bridge != null) unawaited(bridge.close());
    _queue.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showAddDownloadDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) => const _AddDownloadDialog(),
    );
    if (!mounted || url == null) return;
    try {
      await _queue.addUrl(url);
      unawaited(_queue.processQueue());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save download: $error')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Added to queue. Download started.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  List<DownloadTask> _visibleTasks() {
    final category = _categories[_selectedCategory];
    final query = _searchController.text.trim().toLowerCase();
    return _queue.tasks.where((task) {
      final matchesStatus =
          category.status == null || task.status == category.status;
      final matchesQuery =
          query.isEmpty ||
          task.fileName.toLowerCase().contains(query) ||
          task.url.toLowerCase().contains(query);
      return matchesStatus && matchesQuery;
    }).toList();
  }

  int _count(DownloadStatus? status) => _queue.tasks
      .where((task) => status == null || task.status == status)
      .length;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _queue,
      builder: (context, _) {
        final category = _categories[_selectedCategory];
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                _Sidebar(
                  categories: _categories,
                  counts: _categories
                      .map((item) => _count(item.status))
                      .toList(),
                  selectedIndex: _selectedCategory,
                  settingsSelected: _settingsOpen,
                  onSelected: (index) => setState(() {
                    _settingsOpen = false;
                    _selectedCategory = index;
                  }),
                  onSettings: () => setState(() => _settingsOpen = true),
                ),
                Expanded(
                  child: _settingsOpen
                      ? _SettingsPanel(
                          downloadDirectory: _downloadDirectory,
                          isUpdatingDirectory: _isUpdatingDirectory,
                          onChooseDirectory: _chooseDownloadDirectory,
                          onResetDirectory: _resetDownloadDirectory,
                        )
                      : Column(
                          children: [
                            _TopBar(
                              searchOpen: _searchOpen,
                              searchController: _searchController,
                              onSearch: () =>
                                  setState(() => _searchOpen = !_searchOpen),
                              onSearchChanged: (_) => setState(() {}),
                            ),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) =>
                                    SingleChildScrollView(
                                      padding: EdgeInsets.fromLTRB(
                                        constraints.maxWidth < 900 ? 24 : 40,
                                        32,
                                        constraints.maxWidth < 900 ? 24 : 40,
                                        32,
                                      ),
                                      child: Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 1320,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _PageHeading(
                                                selectedCategory:
                                                    category.label,
                                                onAdd: _showAddDownloadDialog,
                                              ),
                                              const SizedBox(height: 28),
                                              _DownloadListCard(
                                                title: category.label,
                                                tasks: _visibleTasks(),
                                                isLoading: _queue.isLoading,
                                                loadError: _queue.loadError,
                                                onAdd: _showAddDownloadDialog,
                                                onPause: (task) => unawaited(
                                                  _queue.pauseDownload(task.id),
                                                ),
                                                onResume: (task) => unawaited(
                                                  _queue.resumeDownload(
                                                    task.id,
                                                  ),
                                                ),
                                                onCancel: (task) => unawaited(
                                                  _queue.cancelDownload(
                                                    task.id,
                                                  ),
                                                ),
                                                onRetry: (task) => unawaited(
                                                  _queue.retryDownload(task.id),
                                                ),
                                                onClearTaskHistory: (task) =>
                                                    unawaited(
                                                      _clearTaskHistory(task),
                                                    ),
                                                onDeleteFile: (task) => unawaited(
                                                  _confirmDeleteDownloadedFile(
                                                    task,
                                                  ),
                                                ),
                                                showClearHistory:
                                                    _selectedCategory == 0,
                                                hasHistory: _queue.tasks.any(
                                                  (task) =>
                                                      task.status ==
                                                          DownloadStatus
                                                              .completed ||
                                                      task.status ==
                                                          DownloadStatus
                                                              .failed ||
                                                      task.status ==
                                                          DownloadStatus
                                                              .canceled,
                                                ),
                                                onClearHistory: () => unawaited(
                                                  _confirmClearHistory(),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.downloadDirectory,
    required this.isUpdatingDirectory,
    required this.onChooseDirectory,
    required this.onResetDirectory,
  });

  final String? downloadDirectory;
  final bool isUpdatingDirectory;
  final VoidCallback onChooseDirectory;
  final VoidCallback onResetDirectory;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 74,
          padding: const EdgeInsets.symmetric(horizontal: 30),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE8EDF4))),
          ),
          alignment: Alignment.centerLeft,
          child: const Text(
            'Internet Download Manager',
            style: TextStyle(
              color: _ink,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Settings',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose where new downloads are saved.',
                      style: TextStyle(color: _muted, fontSize: 14),
                    ),
                    const SizedBox(height: 28),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE8EDF4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Download location',
                            style: TextStyle(
                              color: _ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'New downloads will be saved in this folder. '
                            'Existing downloads keep their current location.',
                            style: TextStyle(color: _muted, fontSize: 13),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4F7FB),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: SelectableText(
                              downloadDirectory ?? 'Loading…',
                              style: const TextStyle(
                                color: Color(0xFF40516A),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              FilledButton.icon(
                                onPressed: isUpdatingDirectory
                                    ? null
                                    : onChooseDirectory,
                                icon: const Icon(Icons.folder_open_outlined),
                                label: const Text('Choose folder'),
                              ),
                              OutlinedButton(
                                onPressed: isUpdatingDirectory
                                    ? null
                                    : onResetDirectory,
                                child: const Text('Use Downloads folder'),
                              ),
                              if (isUpdatingDirectory)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4, top: 8),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.categories,
    required this.counts,
    required this.selectedIndex,
    required this.settingsSelected,
    required this.onSelected,
    required this.onSettings,
  });

  final List<_Category> categories;
  final List<int> counts;
  final int selectedIndex;
  final bool settingsSelected;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 244,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE8EDF4))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 18, 30),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2586D1), Color(0xFF145A9C)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.download_rounded,
                    color: Colors.white,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 11),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'IDM',
                        style: TextStyle(
                          color: _ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .4,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'DOWNLOAD MANAGER',
                        style: TextStyle(
                          color: _muted,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(22, 0, 16, 11),
            child: Text(
              'LIBRARY',
              style: TextStyle(
                color: Color(0xFF9AA6B6),
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          for (var i = 0; i < categories.length; i++)
            _CategoryTile(
              category: categories[i],
              count: counts[i],
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
          const Spacer(),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          InkWell(
            onTap: onSettings,
            child: Container(
              color: settingsSelected ? const Color(0xFFEAF3FB) : Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 15, 16, 19),
              child: Row(
                children: [
                  Icon(
                    Icons.settings_outlined,
                    size: 18,
                    color: settingsSelected ? _blue : _muted,
                  ),
                  const SizedBox(width: 11),
                  Text(
                    'Settings',
                    style: TextStyle(
                      color: settingsSelected ? _blue : const Color(0xFF58677C),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const Text(
                    'v1.0.0',
                    style: TextStyle(color: Color(0xFFA1ACBA), fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final _Category category;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _blue : _muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? const Color(0xFFEAF4FC) : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
            child: Row(
              children: [
                Icon(category.icon, size: 18, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    category.label,
                    style: TextStyle(
                      color: selected ? _blue : const Color(0xFF59677A),
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: TextStyle(
                    color: selected ? _blue : const Color(0xFF9AA6B6),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.searchOpen,
    required this.searchController,
    required this.onSearch,
    required this.onSearchChanged,
  });

  final bool searchOpen;
  final TextEditingController searchController;
  final VoidCallback onSearch;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE8EDF4))),
      ),
      child: Row(
        children: [
          const Spacer(),
          if (searchOpen)
            SizedBox(
              width: 220,
              height: 36,
              child: TextField(
                autofocus: true,
                controller: searchController,
                onChanged: onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search downloads',
                  hintStyle: const TextStyle(fontSize: 12),
                  prefixIcon: const Icon(Icons.search, size: 17),
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: _canvas,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Search',
            onPressed: onSearch,
            icon: const Icon(
              Icons.search_rounded,
              color: Color(0xFF65758A),
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageHeading extends StatelessWidget {
  const _PageHeading({required this.selectedCategory, required this.onAdd});

  final String selectedCategory;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                selectedCategory,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Manage and organize your file transfers.',
                style: TextStyle(color: _muted, fontSize: 13),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded, size: 19),
          label: const Text('Add URL'),
          style: FilledButton.styleFrom(
            backgroundColor: _blue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
            textStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DownloadListCard extends StatelessWidget {
  const _DownloadListCard({
    required this.title,
    required this.tasks,
    required this.isLoading,
    required this.loadError,
    required this.onAdd,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.showClearHistory,
    required this.hasHistory,
    required this.onClearHistory,
    required this.onClearTaskHistory,
    required this.onDeleteFile,
  });

  final String title;
  final List<DownloadTask> tasks;
  final bool isLoading;
  final String? loadError;
  final VoidCallback onAdd;
  final ValueChanged<DownloadTask> onPause;
  final ValueChanged<DownloadTask> onResume;
  final ValueChanged<DownloadTask> onCancel;
  final ValueChanged<DownloadTask> onRetry;
  final bool showClearHistory;
  final bool hasHistory;
  final VoidCallback onClearHistory;
  final ValueChanged<DownloadTask> onClearTaskHistory;
  final ValueChanged<DownloadTask> onDeleteFile;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE8EDF4)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 18, 18),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${tasks.length} items',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                const SizedBox(width: 13),
                PopupMenuButton<_DownloadListOption>(
                  enabled: showClearHistory,
                  tooltip: 'More options',
                  onSelected: (option) {
                    if (option == _DownloadListOption.clearHistory) {
                      onClearHistory();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<_DownloadListOption>(
                      value: _DownloadListOption.clearHistory,
                      enabled: hasHistory,
                      child: const Text('Clear all history'),
                    ),
                  ],
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          const _TableHeader(),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          if (tasks.isNotEmpty)
            for (final task in tasks)
              _DownloadRow(
                task: task,
                onPause: onPause,
                onResume: onResume,
                onCancel: onCancel,
                onRetry: onRetry,
                onClearHistory: onClearTaskHistory,
                onDeleteFile: onDeleteFile,
              )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 52, horizontal: 24),
              child: Column(
                children: [
                  Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F6FB),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.file_download_outlined,
                      size: 31,
                      color: Color(0xFF6E9FC6),
                    ),
                  ),
                  const SizedBox(height: 17),
                  Text(
                    isLoading
                        ? 'Loading your downloads…'
                        : loadError == null
                        ? 'Your download list is empty'
                        : 'Could not load saved downloads',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    loadError ?? 'Add a file URL and it will show up here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                  if (!isLoading && loadError == null) ...[
                    const SizedBox(height: 19),
                    OutlinedButton.icon(
                      onPressed: onAdd,
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: const Text('Add your first download'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _blue,
                        side: const BorderSide(color: Color(0xFFB9D5EA)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onRetry,
    required this.onClearHistory,
    required this.onDeleteFile,
  });

  final DownloadTask task;
  final ValueChanged<DownloadTask> onPause;
  final ValueChanged<DownloadTask> onResume;
  final ValueChanged<DownloadTask> onCancel;
  final ValueChanged<DownloadTask> onRetry;
  final ValueChanged<DownloadTask> onClearHistory;
  final ValueChanged<DownloadTask> onDeleteFile;

  @override
  Widget build(BuildContext context) {
    final date = task.createdAt.toLocal();
    final (badgeBackground, badgeForeground) = _statusColors(task.status);
    final dateLabel =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF4FC),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        Icons.insert_drive_file_outlined,
                        color: _blue,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${task.destinationDirectory} · $dateLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: _muted, fontSize: 10),
                          ),
                          if (task.status == DownloadStatus.downloading) ...[
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                minHeight: 4,
                                value:
                                    task.totalBytes == null ||
                                        task.totalBytes == 0
                                    ? null
                                    : (task.receivedBytes / task.totalBytes!)
                                          .clamp(0, 1)
                                          .toDouble(),
                                color: _blue,
                                backgroundColor: const Color(0xFFE7EEF5),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_formatBytes(task.speedBytesPerSecond.round())}/s${_eta(task)}',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                          if (task.status == DownloadStatus.failed &&
                              task.errorMessage != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              task.errorMessage!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFBE4141),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  task.totalBytes != null
                      ? '${_formatBytes(task.receivedBytes)} / ${_formatBytes(task.totalBytes!)}'
                      : task.receivedBytes > 0
                      ? _formatBytes(task.receivedBytes)
                      : '—',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF66758A),
                    fontSize: 11,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBackground,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusLabel(task.status),
                      style: TextStyle(
                        color: badgeForeground,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 38,
                child: PopupMenuButton<String>(
                  tooltip: 'Download actions',
                  onSelected: (action) {
                    switch (action) {
                      case 'pause':
                        onPause(task);
                      case 'resume':
                        onResume(task);
                      case 'cancel':
                        onCancel(task);
                      case 'retry':
                        onRetry(task);
                      case 'clearHistory':
                        onClearHistory(task);
                      case 'deleteFile':
                        onDeleteFile(task);
                    }
                  },
                  itemBuilder: (context) => [
                    ...switch (task.status) {
                      DownloadStatus.queued => const [
                        PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                      ],
                      DownloadStatus.downloading => const [
                        PopupMenuItem(value: 'pause', child: Text('Pause')),
                        PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                      ],
                      DownloadStatus.paused => const [
                        PopupMenuItem(value: 'resume', child: Text('Resume')),
                        PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                      ],
                      DownloadStatus.failed ||
                      DownloadStatus.canceled => const [
                        PopupMenuItem(value: 'retry', child: Text('Retry')),
                      ],
                      DownloadStatus.completed => const [],
                    },
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'clearHistory',
                      enabled:
                          task.status == DownloadStatus.completed ||
                          task.status == DownloadStatus.failed ||
                          task.status == DownloadStatus.canceled,
                      child: const Text('Clear history'),
                    ),
                    PopupMenuItem(
                      value: 'deleteFile',
                      enabled: task.status == DownloadStatus.completed,
                      child: const Text('Delete file'),
                    ),
                  ],
                  icon: const Icon(Icons.more_vert_rounded, size: 18),
                ),
              ),
            ],
          ),
        ),
        const Divider(
          height: 1,
          indent: 22,
          endIndent: 22,
          color: Color(0xFFF0F2F6),
        ),
      ],
    );
  }

  String _statusLabel(DownloadStatus status) => switch (status) {
    DownloadStatus.queued => 'Queued',
    DownloadStatus.downloading => 'Downloading',
    DownloadStatus.paused => 'Paused',
    DownloadStatus.completed => 'Completed',
    DownloadStatus.failed => 'Failed',
    DownloadStatus.canceled => 'Canceled',
  };

  (Color, Color) _statusColors(DownloadStatus status) => switch (status) {
    DownloadStatus.queued => (const Color(0xFFF0F3F7), const Color(0xFF64748B)),
    DownloadStatus.downloading => (const Color(0xFFEAF4FC), _blue),
    DownloadStatus.paused => (const Color(0xFFFFF5E7), const Color(0xFFB97813)),
    DownloadStatus.completed => (
      const Color(0xFFEAF7F1),
      const Color(0xFF27845F),
    ),
    DownloadStatus.failed => (const Color(0xFFFDECEC), const Color(0xFFBE4141)),
    DownloadStatus.canceled => (
      const Color(0xFFF0F3F7),
      const Color(0xFF64748B),
    ),
  };

  String _eta(DownloadTask task) {
    if (task.totalBytes == null || task.speedBytesPerSecond <= 0) return '';
    final remainingBytes = (task.totalBytes! - task.receivedBytes).clamp(
      0,
      task.totalBytes!,
    );
    final seconds = (remainingBytes / task.speedBytesPerSecond).ceil();
    if (seconds < 60) return ' · $seconds sec left';
    if (seconds < 3600) return ' · ${seconds ~/ 60} min left';
    return ' · ${seconds ~/ 3600} hr left';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('FILE NAME', style: _tableLabel)),
          Expanded(
            flex: 2,
            child: Text('SIZE', textAlign: TextAlign.right, style: _tableLabel),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'STATUS',
              textAlign: TextAlign.right,
              style: _tableLabel,
            ),
          ),
          SizedBox(width: 38),
        ],
      ),
    );
  }
}

const _tableLabel = TextStyle(
  color: Color(0xFF98A5B5),
  fontSize: 9,
  fontWeight: FontWeight.w800,
  letterSpacing: .8,
);

class _AddDownloadDialog extends StatefulWidget {
  const _AddDownloadDialog();

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  final _controller = TextEditingController();
  String? _errorText;

  void _submit() {
    final text = _controller.text.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _errorText = 'Enter a valid HTTP or HTTPS URL.');
      return;
    }
    Navigator.of(context).pop(uri.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add new download',
                style: TextStyle(
                  color: _ink,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              const Text(
                'Paste a direct link to the file you want to download.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 21),
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                onChanged: (_) {
                  if (_errorText != null) setState(() => _errorText = null);
                },
                decoration: InputDecoration(
                  labelText: 'Download URL',
                  hintText: 'https://example.com/file.zip',
                  prefixIcon: const Icon(Icons.link_rounded, size: 19),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 15),
                  errorText: _errorText,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submit,
                    child: const Text('Add to queue'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
