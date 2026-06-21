import 'package:flutter_test/flutter_test.dart';
import 'package:pir_motor_camera/main.dart';

void main() {
  testWidgets('Uygulama açılıyor', (WidgetTester tester) async {
    await tester.pumpWidget(const PirHubApp());
    expect(find.text('PIR · Motor · Kamera'), findsOneWidget);
  });
}
