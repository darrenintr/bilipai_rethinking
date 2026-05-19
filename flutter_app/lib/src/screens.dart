import 'package:flutter/material.dart';

import 'models.dart';
import 'widgets.dart';

class BiliPaiShell extends StatefulWidget {
  const BiliPaiShell({
    super.key,
    required this.repository,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final BiliPaiRepository repository;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<BiliPaiShell> createState() => _BiliPaiShellState();
}

class _BiliPaiShellState extends State<BiliPaiShell> {
  AppTab _tab = AppTab.home;
  VideoItem? _selectedVideo;

  @override
  Widget build(BuildContext context) {
    if (_selectedVideo != null) {
      return VideoDetailScreen(
        video: _selectedVideo!,
        onBack: () => setState(() => _selectedVideo = null),
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 840;
    final body = _buildTabBody();

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (useRail)
              NavigationRail(
                selectedIndex: _tab.index,
                onDestinationSelected: (index) {
                  setState(() => _tab = AppTab.values[index]);
                },
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: BiliPaiMark(),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: Text('Home'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.dynamic_feed_outlined),
                    selectedIcon: Icon(Icons.dynamic_feed_rounded),
                    label: Text('Dynamic'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.live_tv_outlined),
                    selectedIcon: Icon(Icons.live_tv_rounded),
                    label: Text('Live'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: Text('Mine'),
                  ),
                ],
              ),
            Expanded(child: body),
          ],
        ),
      ),
      bottomNavigationBar: useRail
          ? null
          : NavigationBar(
              selectedIndex: _tab.index,
              onDestinationSelected: (index) {
                setState(() => _tab = AppTab.values[index]);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.dynamic_feed_outlined),
                  selectedIcon: Icon(Icons.dynamic_feed_rounded),
                  label: 'Dynamic',
                ),
                NavigationDestination(
                  icon: Icon(Icons.live_tv_outlined),
                  selectedIcon: Icon(Icons.live_tv_rounded),
                  label: 'Live',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  selectedIcon: Icon(Icons.person_rounded),
                  label: 'Mine',
                ),
              ],
            ),
    );
  }

  Widget _buildTabBody() {
    switch (_tab) {
      case AppTab.home:
        return HomeScreen(
          repository: widget.repository,
          onVideoSelected: (video) => setState(() => _selectedVideo = video),
        );
      case AppTab.dynamic:
        return DynamicScreen(
          repository: widget.repository,
          onVideoSelected: (video) => setState(() => _selectedVideo = video),
        );
      case AppTab.live:
        return LiveScreen(repository: widget.repository);
      case AppTab.profile:
        return ProfileScreen(
          repository: widget.repository,
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
        );
    }
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.onVideoSelected,
  });

  final BiliPaiRepository repository;
  final ValueChanged<VideoItem> onVideoSelected;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HomeCategory _category = HomeCategory.recommend;
  late Future<List<VideoItem>> _feedFuture;
  late Future<List<TodayWatchItem>> _todayWatchFuture;

  @override
  void initState() {
    super.initState();
    _feedFuture = widget.repository.fetchHomeFeed(_category);
    _todayWatchFuture = widget.repository.fetchTodayWatchQueue();
  }

  void _selectCategory(HomeCategory category) {
    setState(() {
      _category = category;
      _feedFuture = widget.repository.fetchHomeFeed(category);
    });
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _feedFuture = widget.repository.fetchHomeFeed(_category);
          _todayWatchFuture = widget.repository.fetchTodayWatchQueue();
        });
        await _feedFuture;
      },
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('BiliPai'),
            actions: [
              IconButton(
                tooltip: 'Search',
                onPressed: () {},
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                tooltip: 'Inbox',
                onPressed: () {},
                icon: const Icon(Icons.notifications_none_rounded),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: CategoryStrip(
                selected: _category,
                onSelected: _selectCategory,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: FutureBuilder<List<TodayWatchItem>>(
                future: _todayWatchFuture,
                builder: (context, snapshot) {
                  final items = snapshot.data;
                  if (items == null) {
                    return const TodayWatchSkeleton();
                  }
                  return TodayWatchPanel(
                    items: items,
                    onVideoSelected: widget.onVideoSelected,
                  );
                },
              ),
            ),
          ),
          FutureBuilder<List<VideoItem>>(
            future: _feedFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SliverPadding(
                  padding: EdgeInsets.all(16),
                  sliver: SliverGridSkeleton(),
                );
              }
              final videos = snapshot.data!;
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _gridColumnsForWidth(MediaQuery.sizeOf(context).width),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: videos.length,
                  itemBuilder: (context, index) {
                    return VideoCard(
                      video: videos[index],
                      onTap: () => widget.onVideoSelected(videos[index]),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.video,
    required this.onBack,
  });

  final VideoItem video;
  final VoidCallback onBack;

  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  bool _danmakuEnabled = true;
  bool _audioMode = false;
  double _speed = 1;

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final detail = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          video.title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            MetricChip(icon: Icons.play_arrow_rounded, label: compactCount(video.views)),
            MetricChip(icon: Icons.chat_bubble_rounded, label: compactCount(video.danmakuCount)),
            MetricChip(icon: Icons.thumb_up_alt_rounded, label: compactCount(video.likeCount)),
            MetricChip(icon: Icons.schedule_rounded, label: formatDuration(video.duration)),
          ],
        ),
        const SizedBox(height: 16),
        ActionPanel(
          children: [
            TogglePill(
              icon: Icons.subtitles_rounded,
              label: 'Danmaku',
              selected: _danmakuEnabled,
              onTap: () => setState(() => _danmakuEnabled = !_danmakuEnabled),
            ),
            TogglePill(
              icon: Icons.headphones_rounded,
              label: 'Audio',
              selected: _audioMode,
              onTap: () => setState(() => _audioMode = !_audioMode),
            ),
            PopupMenuButton<double>(
              tooltip: 'Playback speed',
              initialValue: _speed,
              onSelected: (value) => setState(() => _speed = value),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 0.5, child: Text('0.5x')),
                PopupMenuItem(value: 0.75, child: Text('0.75x')),
                PopupMenuItem(value: 1, child: Text('1.0x')),
                PopupMenuItem(value: 1.25, child: Text('1.25x')),
                PopupMenuItem(value: 1.5, child: Text('1.5x')),
                PopupMenuItem(value: 2, child: Text('2.0x')),
              ],
              child: TogglePill(
                icon: Icons.speed_rounded,
                label: '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                selected: false,
                onTap: null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SectionHeader(title: 'Comments', actionLabel: 'Sort'),
        const SizedBox(height: 8),
        for (final comment in _comments) CommentTile(comment: comment),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(video.ownerName),
        actions: [
          IconButton(
            tooltip: 'Picture in picture',
            onPressed: () {},
            icon: const Icon(Icons.picture_in_picture_alt_rounded),
          ),
          IconButton(
            tooltip: 'More',
            onPressed: () {},
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: PlayerSurface(video: video, danmakuEnabled: _danmakuEnabled),
                  ),
                ),
                Expanded(flex: 2, child: detail),
              ],
            )
          : Column(
              children: [
                PlayerSurface(video: video, danmakuEnabled: _danmakuEnabled),
                Expanded(child: detail),
              ],
            ),
    );
  }
}

class DynamicScreen extends StatelessWidget {
  const DynamicScreen({
    super.key,
    required this.repository,
    required this.onVideoSelected,
  });

  final BiliPaiRepository repository;
  final ValueChanged<VideoItem> onVideoSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dynamic')),
      body: FutureBuilder<List<DynamicPost>>(
        future: repository.fetchDynamicFeed(),
        builder: (context, snapshot) {
          final posts = snapshot.data;
          if (posts == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              return DynamicPostCard(
                post: posts[index],
                onVideoSelected: onVideoSelected,
              );
            },
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemCount: posts.length,
          );
        },
      ),
    );
  }
}

class LiveScreen extends StatelessWidget {
  const LiveScreen({
    super.key,
    required this.repository,
  });

  final BiliPaiRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        actions: [
          IconButton(
            tooltip: 'Areas',
            onPressed: () {},
            icon: const Icon(Icons.grid_view_rounded),
          ),
        ],
      ),
      body: FutureBuilder<List<LiveRoom>>(
        future: repository.fetchLiveRooms(),
        builder: (context, snapshot) {
          final rooms = snapshot.data;
          if (rooms == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumnsForWidth(MediaQuery.sizeOf(context).width),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.82,
            ),
            itemCount: rooms.length,
            itemBuilder: (context, index) => LiveRoomCard(room: rooms[index]),
          );
        },
      ),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.repository,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final BiliPaiRepository repository;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const ProfileHeader(),
        const SizedBox(height: 16),
        ThemeModeControl(
          themeMode: themeMode,
          onChanged: onThemeModeChanged,
        ),
        const SizedBox(height: 16),
        FutureBuilder<List<PluginInfo>>(
          future: repository.fetchPlugins(),
          builder: (context, snapshot) {
            final plugins = snapshot.data;
            if (plugins == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return PluginCenterPanel(plugins: plugins);
          },
        ),
        const SizedBox(height: 16),
        for (final section in repository.settingsSections()) ...[
          SettingsSectionCard(section: section),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

int _gridColumnsForWidth(double width) {
  if (width >= 1240) return 5;
  if (width >= 980) return 4;
  if (width >= 640) return 3;
  return 2;
}

const _comments = <String>[
  'The adaptive layout already feels close to the Android app on tablets.',
  'Please keep the player controls reachable with one hand in portrait.',
  'A native iOS player bridge would be useful for background audio and PiP.',
];
