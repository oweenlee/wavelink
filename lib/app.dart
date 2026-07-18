import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme/app_theme.dart';
import 'pages/library_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'pages/now_playing_page.dart';
import 'widgets/mini_player_bar.dart';

class WaveLinkApp extends StatelessWidget {
  const WaveLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WaveLink Mobile',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentTab = 0;

  @override
  Widget build(BuildContext context) {
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
                        _getTitle(),
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
                Expanded(
                  child: IndexedStack(
                    index: _currentTab,
                    children: const [
                      LibraryPage(),
                      NowPlayingPage(),
                      SearchPage(),
                      SettingsPage(),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayerBar(onTap: () => _openNowPlaying(context)),
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
                      label: '曲库',
                      isSelected: _currentTab == 0,
                      onTap: () => setState(() => _currentTab = 0),
                    ),
                    _NavItem(
                      icon: Icons.equalizer_rounded,
                      label: '播放',
                      isSelected: _currentTab == 1,
                      onTap: () => _openNowPlaying(context),
                    ),
                    _NavItem(
                      icon: Icons.search_rounded,
                      label: '搜索',
                      isSelected: _currentTab == 2,
                      onTap: () => setState(() => _currentTab = 2),
                    ),
                    _NavItem(
                      icon: Icons.settings_rounded,
                      label: '设置',
                      isSelected: _currentTab == 3,
                      onTap: () => setState(() => _currentTab = 3),
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

  String _getTitle() {
    switch (_currentTab) {
      case 0:
        return '曲库';
      case 2:
        return '搜索';
      case 3:
        return '设置';
      default:
        return '';
    }
  }

  void _openNowPlaying(BuildContext context) {
    if (_currentTab == 1) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (ctx, anim, secAnim) {
          return FadeTransition(opacity: anim, child: const NowPlayingPage());
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      ),
    );
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
