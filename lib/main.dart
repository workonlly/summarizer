import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';

// Your custom imports
import 'login.dart';
import 'summary_tab.dart';
import 'notes_tab.dart';
import 'ai_tab.dart';
import 'local_gemma_brain.dart';
import 'notification_manager.dart'; // 🔔 Make sure this file exists

void main() async {
  // 🟢 1. Ensure Flutter framework is ready
  WidgetsFlutterBinding.ensureInitialized();

  // 🔔 2. Wake up the Notification Manager
  await NotificationManager().init();

  // 🟢 3. Initialize the Local AI Brain
  try {
    await LocalGemmaBrain().initialize();
  } catch (e) {
    print("❌ Critical: Failed to init Gemma in main: $e");
  }
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SummariZer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F46E5), 
          primary: const Color(0xFF4F46E5),
          surface: Colors.white,
        ),
        textTheme: GoogleFonts.plusJakartaSansTextTheme(),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  Future<bool> _checkStoredData() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('userName') ?? '';
    return name.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _checkStoredData(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.data == true
            ? const MainDashboard()
            : const LoginScreen();
      },
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int _currentIndex = 0;
  String _userName = "";

  @override
  void initState() {
    super.initState();
    _loadUserName();
    _requestNotificationPermissions(); // 🔔 Ask for permission on start
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!LocalGemmaBrain().isModelReady.value) {
        _showAIPrompt();
      }
    });
  }

  // 🔔 Request Permissions for Android 13+
  Future<void> _requestNotificationPermissions() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      print("🔔 Notification Permission Status: $status");
      
      if (status.isGranted) {
        // Test notification to console and device
        NotificationManager().showNotification(
          id: 0,
          title: "System Ready",
          body: "SummariZer Notification Manager is active.",
        );
      }
    }
  }

  Future<void> _loadUserName() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _userName = prefs.getString('userName') ?? 'User');
    }
  }

  void _showAIPrompt() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'AI status: Offline. Tap the status light to download the brain.',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: const Color(0xFF1E293B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.only(bottom: 100, left: 16, right: 16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
    if (index == 1) {
      print("🚀 Dashboard: Preparing Gemma for Note-taking...");
      LocalGemmaBrain().warmUp();
    }
  }

  void _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MyApp()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      const SummaryTab(),
      const NotesTab(),
      const AITab(),
    ];

    return Scaffold(
      extendBody: true, 
      backgroundColor: const Color(0xFFF8FAFC), 
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(100),
        child: _buildGlassHeader(),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        switchInCurve: Curves.easeInOut,
        child: Padding(
          key: ValueKey<int>(_currentIndex),
          padding: const EdgeInsets.only(bottom: 10),
          child: screens[_currentIndex],
        ),
      ),
      bottomNavigationBar: _buildWhiteBlueNav(),
    );
  }

  Widget _buildGlassHeader() {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.8),
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade200.withOpacity(0.5)),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Hey, $_userName',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildAIStatusRow(),
                  ],
                ),
                _buildHeaderAction(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAIStatusRow() {
    return Row(
      children: [
        const _AILightIndicator(), 
        const SizedBox(width: 8),
        ValueListenableBuilder<bool>(
          valueListenable: LocalGemmaBrain().isModelReady,
          builder: (context, isReady, child) {
            if (isReady) {
              return const Text(
                'AI Brain Active',
                style: TextStyle(color: Color(0xFF10B981), fontSize: 12, fontWeight: FontWeight.bold),
              );
            } 
            return ValueListenableBuilder<bool>(
              valueListenable: LocalGemmaBrain().isDownloading,
              builder: (context, isDownloading, child) {
                if (!isDownloading) {
                  return GestureDetector(
                    onTap: () => LocalGemmaBrain().initialize(),
                    child: Text(
                      'Tap to Download AI',
                      style: TextStyle(color: Theme.of(context).primaryColor, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  );
                }
                return ValueListenableBuilder<int>(
                  valueListenable: LocalGemmaBrain().downloadProgress,
                  builder: (context, progress, child) {
                    if (progress < 0) return const Text('Error. Retry?', style: TextStyle(color: Colors.red, fontSize: 12));
                    return Text('Installing... $progress%', style: const TextStyle(color: Color(0xFF64748B), fontSize: 12));
                  },
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildHeaderAction() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: IconButton(
        icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 22),
        onPressed: _showLogoutConfirm,
      ),
    );
  }

  Widget _buildWhiteBlueNav() {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 30),
      height: 72,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4F46E5).withOpacity(0.12),
            blurRadius: 25,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _navItem(0, Icons.grid_view_rounded, "Dash"),
          _navItem(1, Icons.keyboard_voice_rounded, "Notes"),
          _navItem(2, Icons.auto_awesome_rounded, "AI"),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    bool active = _currentIndex == index;
    return GestureDetector(
      onTap: () => _onTabTapped(index),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF4F46E5).withOpacity(0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Icon(icon, color: active ? const Color(0xFF4F46E5) : const Color(0xFF94A3B8), size: 24),
            if (active) ...[
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(color: Color(0xFF4F46E5), fontWeight: FontWeight.w700, fontSize: 13)),
            ]
          ],
        ),
      ),
    );
  }

  void _showLogoutConfirm() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to log out of SummariZer?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: _handleLogout,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}

class _AILightIndicator extends StatefulWidget {
  const _AILightIndicator();

  @override
  State<_AILightIndicator> createState() => _AILightIndicatorState();
}

class _AILightIndicatorState extends State<_AILightIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LocalGemmaBrain().isModelReady,
      builder: (context, isReady, child) {
        return ValueListenableBuilder<bool>(
          valueListenable: LocalGemmaBrain().isDownloading,
          builder: (context, isDownloading, child) {
            final color = isReady ? const Color(0xFF10B981) : (isDownloading ? Colors.orange : Colors.redAccent);
            return AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withOpacity(isReady ? 1.0 : _controller.value),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(0.5 * _controller.value),
                        blurRadius: 8, spreadRadius: 2,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}