import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'services/settings.dart';
import 'services/storage_platform.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  final state = AppState(
    storage: createPlatformStorage(),
    settings: settings,
  );
  await state.init();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MoatApp(),
    ),
  );
}
