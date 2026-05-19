import 'package:flutter/material.dart';
import 'package:bilipai_flutter/app/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home feed and settings entry render', (tester) async {
    await tester.pumpWidget(const BiliPaiApp());
    await tester.pumpAndSettle();

    expect(find.text('BiliPai Flutter'), findsOneWidget);
    expect(find.text('Kotlin to Flutter migration diary #1'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
