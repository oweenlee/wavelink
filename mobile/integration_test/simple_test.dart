import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wavelink_mobile/ui/core/app.dart';
import 'package:wavelink_mobile/ui/features/playback/view_models/playback_controller.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App renders', (WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 触发编排层接线并启动副作用（与 main.dart 一致）
    container.read(playbackControllerProvider).bootstrap();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const WaveLinkApp(),
      ),
    );
    expect(find.byType(WaveLinkApp), findsOneWidget);
  });
}
