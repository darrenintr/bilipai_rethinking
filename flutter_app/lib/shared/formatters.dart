String formatDuration(int totalSeconds) {
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatViews(int views) {
  if (views >= 10000) {
    final value = (views / 10000).toStringAsFixed(1);
    return '${value}w views';
  }
  return '$views views';
}
