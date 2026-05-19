import 'package:bilipai_flutter/domain/feed/feed_item.dart';

abstract class FeedRepository {
  Future<List<FeedItem>> getRecommendedFeed();
}
