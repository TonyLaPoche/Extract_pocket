// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:pocket_extract/app/pocket_extract_app.dart';

void main() {
  testWidgets('PocketExtract s affiche correctement', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PocketExtractApp());
    await tester.pump();

    expect(find.text('PocketExtract'), findsOneWidget);
    expect(find.text('Analyser'), findsOneWidget);
    expect(find.text('Recuperer'), findsOneWidget);
  });
}
