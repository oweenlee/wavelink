import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show PlatformDispatcher;
import '../../l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'theme/app_theme.dart';
import '../features/settings/view_models/locale_provider.dart';
import 'widgets/mini_player_bar.dart';
import 'routes.dart';

class WaveLinkApp extends StatelessWidget {
  const WaveLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeProvider = Provider.of<LocaleProvider>(context);
    final deviceLocale = PlatformDispatcher.instance.locale;
    final locale = localeProvider.resolve(deviceLocale);
    return MaterialApp.router(
      title: 'WaveLink Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: LocaleProvider.supported,
      routerConfig: goRouter,
    );
  }
}

class AppShell extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currentTab = navigationShell.currentIndex;

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppTheme.background,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        _getTitle(currentTab, l10n),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
                Expanded(child: navigationShell),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayerBar(onTap: () => context.push('/now-playing')),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.background,
              border: Border(
                top: BorderSide(
                  color: AppTheme.textTertiary.withValues(alpha: 0.1),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavItem(
                      icon: Icons.library_music_rounded,
                      label: l10n.tabLibrary,
                      isSelected: currentTab == 0,
                      onTap: () => _goTab(0),
                    ),
                    _NavItem(
                      icon: Icons.equalizer_rounded,
                      label: l10n.tabPlay,
                      isSelected: false,
                      onTap: () => context.push('/now-playing'),
                    ),
                    _NavItem(
                      icon: Icons.search_rounded,
                      label: l10n.tabSearch,
                      isSelected: currentTab == 1,
                      onTap: () => _goTab(1),
                    ),
                    _NavItem(
                      icon: Icons.settings_rounded,
                      label: l10n.tabSettings,
                      isSelected: currentTab == 2,
                      onTap: () => _goTab(2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _goTab(int index) {
    navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);
  }

  String _getTitle(int tab, AppLocalizations l10n) {
    switch (tab) {
      case 0:
        return l10n.titleLibrary;
      case 1:
        return l10n.titleSearch;
      case 2:
        return l10n.titleSettings;
      default:
        return '';
    }
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentBlue.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: isSelected ? AppTheme.accentBlue : AppTheme.textTertiary,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppTheme.accentBlue : AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
