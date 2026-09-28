import 'package:flutter_test/flutter_test.dart';

import 'package:hinter/main.dart';

void main() {
  testWidgets('应用能启动并显示首页标题', (WidgetTester tester) async {
    await tester.pumpWidget(const HinterApp());
    expect(find.text('Hinter 口播提词器'), findsOneWidget);
  });
}
