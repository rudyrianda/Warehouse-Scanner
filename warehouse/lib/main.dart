import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'features/warehouse/data/datasources/local_database.dart';
import 'features/warehouse/data/datasources/api_service.dart';
import 'features/warehouse/data/datasources/sync_service.dart';
import 'features/warehouse/data/datasources/master_data_seed.dart'; // ← TAMBAH
import 'features/warehouse/presentation/pages/main_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LocalDatabase.db;

  final isEmpty = await LocalDatabase.isMasterDataEmpty();
  if (isEmpty) {
    // Seed lokal dulu supaya offline pun langsung ada data
    await LocalDatabase.insertMasterData(MasterDataSeed.data); // ← TAMBAH
    print('[MAIN] Seed lokal: ${MasterDataSeed.data.length} items'); // ← TAMBAH
  }

  // Coba update dari server kalau online
  await ApiService.fetchAndCacheMasterData(); // ← pindah ke sini, selalu dipanggil

  SyncService.start();

  AudioPlayer.global.setAudioContext(
    AudioContext(
      android: const AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.sonification,
        usageType: AndroidUsageType.notificationEvent,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        audioMode: AndroidAudioMode.normal,
      ),
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Warehouse',
      theme: AppTheme.theme,
      home: const MainPage(),
    );
  }
}