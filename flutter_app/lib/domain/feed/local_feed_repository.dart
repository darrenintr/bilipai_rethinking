import 'package:bilipai_flutter/domain/feed/feed_item.dart';
import 'package:bilipai_flutter/domain/feed/feed_repository.dart';

class LocalFeedRepository implements FeedRepository {
  @override
  Future<List<FeedItem>> getRecommendedFeed() async {
    return const [
      FeedItem(
        id: 'BV1',
        title: 'Night-friendly coding lo-fi mix',
        uploader: 'BiliPai Music Lab',
        durationSeconds: 1420,
        viewCount: 12800,
      ),
      FeedItem(
        id: 'BV2',
        title: 'Kotlin to Flutter migration diary #1',
        uploader: 'BiliPai Dev',
        durationSeconds: 930,
        viewCount: 9400,
      ),
      FeedItem(
        id: 'BV3',
        title: 'Compose vs Flutter UI architecture notes',
        uploader: 'Mobile Craft',
        durationSeconds: 760,
        viewCount: 16700,
      ),
    ];
  }
}
