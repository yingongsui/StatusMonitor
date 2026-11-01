import 'package:flutter/material.dart';
import 'package:status_monitor/screens/home_screen.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appState = AppState();
  await appState.loadPreferences();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: appState,
      child: const SystemMonitorApp(),
    ),
  );
}

class SystemMonitorApp extends StatelessWidget {
  const SystemMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) => MaterialApp(
        title: "StatusMonitor",
        debugShowCheckedModeBanner: false,
        themeMode: appState.themeMode,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFF8FAFC),
          colorSchemeSeed: Colors.cyan,
          cardColor: Colors.white,
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 1,
            backgroundColor: Color(0xFFF8FAFC),
          ),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0D1117),
          colorSchemeSeed: Colors.cyan,
          cardColor: const Color(0xFF161A22),
          appBarTheme: const AppBarTheme(
            elevation: 0,
            scrolledUnderElevation: 1,
            backgroundColor: Color(0xFF0D1117),
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
