import 'package:flutter_test/flutter_test.dart';
import 'package:songre/main.dart';
import 'package:songre/services/app_state.dart';

void main() {
  testWidgets('SONGRE app smoke test', (WidgetTester tester) async {
    final appState = AppState();
    await tester.pumpWidget(SauveApp(appState: appState));
    expect(find.byType(SauveApp), findsOneWidget);
  });
}
