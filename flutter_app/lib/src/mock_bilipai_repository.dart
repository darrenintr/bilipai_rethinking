import 'package:flutter/material.dart';

import 'models.dart';

class MockBiliPaiRepository implements BiliPaiRepository {
  static const _covers = <String>[
    'https://images.unsplash.com/photo-1498050108023-c5249f4df085?w=900',
    'https://images.unsplash.com/photo-1516321318423-f06f85e504b3?w=900',
    'https://images.unsplash.com/photo-1519389950473-47ba0277781c?w=900',
    'https://images.unsplash.com/photo-1485827404703-89b55fcc595e?w=900',
    'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?w=900',
    'https://images.unsplash.com/photo-1550745165-9bc0b252726f?w=900',
  ];

  final List<VideoItem> _videos = List<VideoItem>.generate(18, (index) {
    final category = HomeCategory.values[index % HomeCategory.values.length];
    return VideoItem(
      bvid: 'BV1FP4y1${1000 + index}',
      cid: 900000 + index,
      title: _titles[index % _titles.length],
      ownerName: _owners[index % _owners.length],
      coverUrl: _covers[index % _covers.length],
      duration: Duration(minutes: 4 + index % 18, seconds: 12 + index % 47),
      views: 82000 + index * 39117,
      danmakuCount: 1400 + index * 263,
      likeCount: 7600 + index * 881,
      tags: [category.label, index.isEven ? 'Night friendly' : 'Deep dive'],
      resumeProgress: index % 5 == 0 ? 0.34 : 0,
    );
  });

  @override
  Future<List<VideoItem>> fetchHomeFeed(HomeCategory category) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (category == HomeCategory.recommend) {
      return _videos;
    }
    return _videos
        .where((video) => video.tags.first == category.label)
        .followedBy(_videos.where((video) => video.tags.first != category.label))
        .take(12)
        .toList();
  }

  @override
  Future<List<TodayWatchItem>> fetchTodayWatchQueue() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return _videos.take(5).map((video) {
      final learnMode = video.cid.isEven;
      return TodayWatchItem(
        video: video,
        mode: learnMode ? 'Learn' : 'Relax',
        reason: learnMode
            ? 'Similar creator, medium length, strong completion history'
            : 'Shorter session, lower stimulation, fresh uploader',
      );
    }).toList();
  }

  @override
  Future<List<DynamicPost>> fetchDynamicFeed() async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    return <DynamicPost>[
      DynamicPost(
        author: 'BiliPai Lab',
        avatarColor: const Color(0xFFFA7298),
        text: 'Testing a compact Flutter feed layout with native-feeling iOS and Android spacing.',
        timeLabel: '12 min ago',
        statsLabel: '2.4k likes  186 replies',
        attachments: [_videos[1]],
      ),
      DynamicPost(
        author: 'Player Team',
        avatarColor: const Color(0xFF34C759),
        text: 'Danmaku density, playback order, and audio mode are the next production port targets.',
        timeLabel: '1 hr ago',
        statsLabel: '981 likes  74 replies',
        attachments: [_videos[2], _videos[3]],
      ),
      DynamicPost(
        author: 'Plugin Center',
        avatarColor: const Color(0xFF007AFF),
        text: 'JSON rule plugins can be moved into a pure Dart policy layer and shared by iOS and Android.',
        timeLabel: 'Yesterday',
        statsLabel: '4.9k likes  322 replies',
        attachments: const [],
      ),
    ];
  }

  @override
  Future<List<LiveRoom>> fetchLiveRooms() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return List<LiveRoom>.generate(8, (index) {
      return LiveRoom(
        roomId: 70000 + index,
        title: _liveTitles[index % _liveTitles.length],
        host: _owners[(index + 2) % _owners.length],
        area: ['Game', 'Music', 'Study', 'Tech'][index % 4],
        coverUrl: _covers[(index + 3) % _covers.length],
        viewerCount: 3100 + index * 2600,
        isFollowing: index % 3 == 0,
      );
    });
  }

  @override
  Future<List<PluginInfo>> fetchPlugins() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return const <PluginInfo>[
      PluginInfo(
        name: 'SponsorBlock',
        description: 'Skip sponsor and promotion segments when a match is available.',
        enabled: true,
        icon: Icons.skip_next_rounded,
        color: Color(0xFFFA7298),
      ),
      PluginInfo(
        name: 'AdBlock',
        description: 'Hide commercial cards from recommendation feeds.',
        enabled: true,
        icon: Icons.visibility_off_rounded,
        color: Color(0xFFFF9500),
      ),
      PluginInfo(
        name: 'Danmaku Plus',
        description: 'Keyword block, highlight, density, and style policies.',
        enabled: true,
        icon: Icons.chat_bubble_rounded,
        color: Color(0xFF5AC8FA),
      ),
      PluginInfo(
        name: 'Eye Protection',
        description: 'Warm filter, reminders, snooze, and night-session pacing.',
        enabled: false,
        icon: Icons.remove_red_eye_rounded,
        color: Color(0xFF34C759),
      ),
      PluginInfo(
        name: 'Today Watch',
        description: 'Local recommendation queue with explainable Relax and Learn modes.',
        enabled: true,
        icon: Icons.auto_awesome_rounded,
        color: Color(0xFFAF52DE),
      ),
    ];
  }

  @override
  List<SettingsSection> settingsSections() {
    return const <SettingsSection>[
      SettingsSection(
        title: 'Appearance',
        items: <SettingsItem>[
          SettingsItem(
            title: 'Theme and accent',
            subtitle: 'System, light, dark, dynamic color, and Bili pink presets',
            icon: Icons.palette_rounded,
          ),
          SettingsItem(
            title: 'Bottom navigation',
            subtitle: 'Labels, floating style, blur, and tablet rail behavior',
            icon: Icons.space_dashboard_rounded,
          ),
        ],
      ),
      SettingsSection(
        title: 'Playback',
        items: <SettingsItem>[
          SettingsItem(
            title: 'Quality and speed',
            subtitle: 'DASH tier selection, long-press speed, and resume policy',
            icon: Icons.high_quality_rounded,
          ),
          SettingsItem(
            title: 'Audio mode',
            subtitle: 'Background playback, sleep timer, and playlist behavior',
            icon: Icons.headphones_rounded,
          ),
        ],
      ),
      SettingsSection(
        title: 'Data',
        items: <SettingsItem>[
          SettingsItem(
            title: 'Cache and downloads',
            subtitle: 'Offline videos, storage location, and cleanup rules',
            icon: Icons.download_for_offline_rounded,
          ),
          SettingsItem(
            title: 'Backup',
            subtitle: 'WebDAV-ready settings import and export surface',
            icon: Icons.cloud_sync_rounded,
          ),
        ],
      ),
    ];
  }
}

const _titles = <String>[
  'Rebuilding a native Bilibili client for smooth daily watching',
  'How adaptive bitrate switching avoids playback stalls',
  'A quiet desk setup for focused coding sessions',
  'Understanding danmaku density and readability tradeoffs',
  'The new Today Watch queue explained with local signals',
  'From Android Compose to Flutter: practical porting notes',
];

const _owners = <String>[
  'Pure Studio',
  'Open Player',
  'Daily Tech',
  'Motion Lab',
  'Flutter Notes',
  'BiliPai Team',
];

const _liveTitles = <String>[
  'Evening code and music stream',
  'Indie game discovery',
  'Study room with low-noise chat',
  'Hardware teardown and repair',
];
