class PlaybackSpeedPolicy {
  static const List<double> allowedSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  double clamp(double requested) {
    if (allowedSpeeds.contains(requested)) {
      return requested;
    }
    return 1.0;
  }
}
