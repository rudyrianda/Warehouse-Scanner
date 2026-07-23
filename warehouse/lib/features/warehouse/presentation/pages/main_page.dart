import 'package:flutter/material.dart';
import '../../../../core/theme/app_theme.dart';
import 'input_page.dart';
import 'data_page.dart';
import 'export_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabs = [
    Tab(icon: Icon(Icons.add_circle_outline, size: 16), text: 'Input'),
    Tab(icon: Icon(Icons.list_alt, size: 16), text: 'Data'),
    Tab(icon: Icon(Icons.file_upload_outlined, size: 16), text: 'Export'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // resizeToAvoidBottomInset: false, // ← TAMBAH INI
      body: SafeArea(
        top: true,
        bottom: true,
        child: Column(
          children: [
            // Top tab bar
            ColoredBox(
              color: AppTheme.primaryBlue,
              child: SizedBox(
                height: 37,
                child: TabBar(
                  controller: _tabController,
                  indicatorColor: Colors.white,
                  indicatorWeight: 2,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: const TextStyle(
                      fontSize: 9, fontWeight: FontWeight.bold),
                  unselectedLabelStyle: const TextStyle(fontSize: 9),
                  labelPadding:
                      const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
                  tabs: _tabs,
                ),
              ),
            ),

            // Pages
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  InputPage(),
                  DataPage(),
                  ExportPage(),
                ],
              ),
            ),
            // Footer text at bottom
            Container(
              color: AppTheme.primaryBlue,
              width: double.infinity,
              height: 15,
              alignment: Alignment.center,
              child: const Text('Panasonic AC-BU',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
            ),
          ],
        ),
      ),
    );
  }
}
