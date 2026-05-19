import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/mock_bilipai_repository.dart';

void main() {
  runApp(BiliPaiFlutterApp(repository: MockBiliPaiRepository()));
}
