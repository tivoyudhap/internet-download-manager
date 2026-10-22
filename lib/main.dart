import 'package:flutter/material.dart';

import 'models/download_task.dart';
import 'services/download_queue_controller.dart';
import 'services/download_queue_store.dart';

const _ink = Color(0xFF172B4D);
const _muted = Color(0xFF718096);
const _blue = Color(0xFF1769AA);
const _canvas = Color(0xFFF4F7FB);

void main() => runApp(const DownloadManagerApp());

class DownloadManagerApp extends StatelessWidget {
  const DownloadManagerApp({super.key, this.queueController});

  final DownloadQueueController? queueController;

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
      home: DownloadsPage(queueController: queueController),
    );
  }
}

class _Category {
  const _Category(this.label, this.icon, this.status);

  final String label;
  final IconData icon;
  final DownloadStatus? status;
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, this.queueController});

  final DownloadQueueController? queueController;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final DownloadQueueController _queue;
  final _searchController = TextEditingController();

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
    _queue =
        widget.queueController ?? DownloadQueueController(DownloadQueueStore());
    _queue.load();
  }

  @override
  void dispose() {
    _queue.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showAddDownloadDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => _AddDownloadDialog(controller: controller),
    );
    controller.dispose();
    if (!mounted || url == null) return;
    try {
      await _queue.addUrl(url);
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
        content: Text(
          'Added to queue. The download engine is not connected yet.',
        ),
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
                  onSelected: (index) =>
                      setState(() => _selectedCategory = index),
                ),
                Expanded(
                  child: Column(
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
                                          selectedCategory: category.label,
                                          onAdd: _showAddDownloadDialog,
                                        ),
                                        const SizedBox(height: 28),
                                        _OverviewCards(
                                          activeCount: _count(
                                            DownloadStatus.downloading,
                                          ),
                                          completedCount: _count(
                                            DownloadStatus.completed,
                                          ),
                                          queuedCount: _count(
                                            DownloadStatus.queued,
                                          ),
                                        ),
                                        const SizedBox(height: 28),
                                        _DownloadListCard(
                                          title: category.label,
                                          tasks: _visibleTasks(),
                                          isLoading: _queue.isLoading,
                                          loadError: _queue.loadError,
                                          onAdd: _showAddDownloadDialog,
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

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.categories,
    required this.counts,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Category> categories;
  final List<int> counts;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

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
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 15, 20, 19),
            child: Row(
              children: [
                Icon(Icons.settings_outlined, size: 18, color: _muted),
                SizedBox(width: 11),
                Text(
                  'Settings',
                  style: TextStyle(
                    color: Color(0xFF58677C),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Spacer(),
                Text(
                  'v1.0.0',
                  style: TextStyle(color: Color(0xFFA1ACBA), fontSize: 11),
                ),
              ],
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
          const Icon(Icons.desktop_windows_outlined, size: 17, color: _muted),
          const SizedBox(width: 9),
          const Text(
            'Desktop app',
            style: TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
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
          const SizedBox(width: 8),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFFE7F1FA),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.person_outline_rounded,
              color: _blue,
              size: 19,
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

class _OverviewCards extends StatelessWidget {
  const _OverviewCards({
    required this.activeCount,
    required this.completedCount,
    required this.queuedCount,
  });

  final int activeCount;
  final int completedCount;
  final int queuedCount;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final cards = [
          _OverviewCard(
            label: 'Active downloads',
            value: '$activeCount',
            icon: Icons.downloading_rounded,
            tint: Color(0xFFEAF4FC),
            iconColor: _blue,
            detail: activeCount == 0
                ? 'Nothing downloading'
                : 'Currently downloading',
          ),
          _OverviewCard(
            label: 'Completed today',
            value: '$completedCount',
            icon: Icons.task_alt_rounded,
            tint: Color(0xFFEAF7F1),
            iconColor: Color(0xFF29956B),
            detail: completedCount == 0
                ? 'Ready when you are'
                : 'Files completed',
          ),
          _OverviewCard(
            label: 'Queue remaining',
            value: '$queuedCount',
            icon: Icons.pending_actions_rounded,
            tint: Color(0xFFFFF5E7),
            iconColor: Color(0xFFD89122),
            detail: queuedCount == 0 ? 'Queue is clear' : 'Waiting to download',
          ),
        ];
        if (compact) {
          return Column(
            children: [
              for (final card in cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: card,
                ),
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              Expanded(child: cards[i]),
            ],
          ],
        );
      },
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.tint,
    required this.iconColor,
    required this.detail,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color tint;
  final Color iconColor;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(19),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE8EDF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                width: 33,
                height: 33,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              color: _ink,
              fontSize: 27,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            detail,
            style: const TextStyle(color: Color(0xFF9AA6B6), fontSize: 11),
          ),
        ],
      ),
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
  });

  final String title;
  final List<DownloadTask> tasks;
  final bool isLoading;
  final String? loadError;
  final VoidCallback onAdd;

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
                IconButton(
                  tooltip: 'More options',
                  onPressed: null,
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          const _TableHeader(),
          const Divider(height: 1, color: Color(0xFFE8EDF4)),
          if (tasks.isNotEmpty)
            for (final task in tasks) _DownloadRow(task: task)
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
  const _DownloadRow({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final date = task.createdAt.toLocal();
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  task.totalBytes == null
                      ? '—'
                      : _formatBytes(task.totalBytes!),
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
                      color: const Color(0xFFFFF5E7),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _statusLabel(task.status),
                      style: const TextStyle(
                        color: Color(0xFFB97813),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 38),
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
  const _AddDownloadDialog({required this.controller});

  final TextEditingController controller;

  @override
  State<_AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<_AddDownloadDialog> {
  String? _errorText;

  void _submit() {
    final text = widget.controller.text.trim();
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
                controller: widget.controller,
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
