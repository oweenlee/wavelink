import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:wavelink_mobile/app.dart';
import 'package:wavelink_mobile/providers/playback_provider.dart';
import 'package:wavelink_mobile/data/repositories/audio_engine_repository.dart';
import 'package:wavelink_mobile/data/repositories/song_repository.dart';
import 'package:wavelink_mobile/data/repositories/preferences_repository.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => PlaybackProvider(
          engineRepo: AudioEngineRepository(),
          songRepo: SongRepository(),
          prefsRepo: PreferencesRepository(),
        ),
        child: const WaveLinkApp(),
      ),
    );
    expect(find.byType(WaveLinkApp), findsOneWidget);
  });
}
