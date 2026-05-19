class FeedItem {
  final String id;
  final String title;
  final String uploader;
  final int durationSeconds;
  final int viewCount;

  const FeedItem({
    required this.id,
    required this.title,
    required this.uploader,
    required this.durationSeconds,
    required this.viewCount,
  });
}
