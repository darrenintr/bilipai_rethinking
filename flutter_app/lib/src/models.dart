import 'package:flutter/material.dart';

enum AppTab {
  home,
  dynamic,
  live,
  profile,
}

enum HomeCategory {
  recommend,
  popular,
  bangumi,
  knowledge,
  tech,
  game,
}

extension HomeCategoryLabel on HomeCategory {
  String get label {
    switch (this) {
      case HomeCategory.recommend:
        return 'Recommend';
      case HomeCategory.popular:
        return 'Popular';
      case HomeCategory.bangumi:
        return 'Bangumi';
      case HomeCategory.knowledge:
        return 'Knowledge';
      case HomeCategory.tech:
        return 'Tech';
      case HomeCategory.game:
        return 'Game';
    }
  }
}

class VideoItem {
  const VideoItem({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.ownerName,
    required this.coverUrl,
    required this.duration,
    required this.views,
    required this.danmakuCount,
    required this.likeCount,
    required this.tags,
    this.resumeProgress = 0,
  });

  final String bvid;
  final int cid;
  final String title;
  final String ownerName;
  final String coverUrl;
  final Duration duration;
  final int views;
  final int danmakuCount;
  final int likeCount;
  final List<String> tags;
  final double resumeProgress;
}

class TodayWatchItem {
  const TodayWatchItem({
    required this.video,
    required this.reason,
    required this.mode,
  });

  final VideoItem video;
  final String reason;
  final String mode;
}

class DynamicPost {
  const DynamicPost({
    required this.author,
    required this.avatarColor,
    required this.text,
    required this.timeLabel,
    required this.statsLabel,
    required this.attachments,
  });

  final String author;
  final Color avatarColor;
  final String text;
  final String timeLabel;
  final String statsLabel;
  final List<VideoItem> attachments;
}

class LiveRoom {
  const LiveRoom({
    required this.roomId,
    required this.title,
    required this.host,
    required this.area,
    required this.coverUrl,
    required this.viewerCount,
    required this.isFollowing,
  });

  final int roomId;
  final String title;
  final String host;
  final String area;
  final String coverUrl;
  final int viewerCount;
  final bool isFollowing;
}

class PluginInfo {
  const PluginInfo({
    required this.name,
    required this.description,
    required this.enabled,
    required this.icon,
    required this.color,
  });

  final String name;
  final String description;
  final bool enabled;
  final IconData icon;
  final Color color;
}

class SettingsSection {
  const SettingsSection({
    required this.title,
    required this.items,
  });

  final String title;
  final List<SettingsItem> items;
}

class SettingsItem {
  const SettingsItem({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;
}

abstract class BiliPaiRepository {
  Future<List<VideoItem>> fetchHomeFeed(HomeCategory category);

  Future<List<TodayWatchItem>> fetchTodayWatchQueue();

  Future<List<DynamicPost>> fetchDynamicFeed();

  Future<List<LiveRoom>> fetchLiveRooms();

  Future<List<PluginInfo>> fetchPlugins();

  List<SettingsSection> settingsSections();
}
