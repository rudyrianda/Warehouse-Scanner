import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'api_service.dart';
import 'warehouse_remote_datasource.dart';

class SyncService {
  static Timer? _timer;
  static Future<bool>? _activeSync;
  static StreamSubscription<List<ConnectivityResult>>? _connSub;
  static bool _wasOffline = false;

  // Instance RemoteDataSource untuk akses syncPendingData()
  static final _remote = WarehouseRemoteDataSource(client: http.Client());

  static void start() {
    // Langsung coba sync sekali saat app start
    _trySyncSilent();
    // Lalu tiap 30 detik (jaring pengaman / retry kalau listener connectivity terlewat)
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _trySyncSilent());

    // FIX: begitu koneksi balik (offline → online), langsung sync saat itu juga.
    // Sebelumnya app menunggu sampai timer 30 detik berikutnya, sehingga
    // layar Data sempat membaca data dari server SEBELUM scan offline
    // sempat ter-upload — terlihat seperti data hilang/"hanya 1 yang kesimpan".
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (isOnline && _wasOffline) {
        print('[SYNC] Koneksi kembali — sync langsung dipicu');
        _trySyncSilent();
      }
      _wasOffline = !isOnline;
    });
  }

  static void stop() {
    _timer?.cancel();
    _connSub?.cancel();
  }

  static Future<void> _trySyncSilent() async {
    await syncNow();
  }

  /// Bisa dipanggil manual dari UI kalau mau force sync.
  /// Return true jika sync berhasil (atau selesai ditunggu), false jika gagal/offline.
  static Future<bool> syncNow() async {
    // Jika sync sedang berjalan, tunggu saja hasilnya
    if (_activeSync != null) {
      print('[SYNC] Menunggu proses sync yang sedang berjalan...');
      return await _activeSync!;
    }

    _activeSync = _doSync();
    try {
      return await _activeSync!;
    } catch (e) {
      print('[SYNC] Error saat force sync: $e');
      return false;
    } finally {
      _activeSync = null; // Selalu reset status ketika selesai
    }
  }

  static Future<bool> _doSync() async {
    try {
      final isOnline = await _checkConnection();
      if (!isOnline) return false;

      // 1. Sync Entries + EntryDetails pending dulu
      await _remote.syncPendingData();
      print('[SYNC] Entries & Details synced');

      // 2. Baru sync ScannedItems pending
      final scanResult = await ApiService.syncPendingScans();
      if (scanResult.success > 0 || scanResult.failed > 0) {
        print('[SYNC] Scans ✓${scanResult.success} ✗${scanResult.failed}');
      }

      // FIX: Cek apakah masih ada scan PENDING (belum dicoba).
      // Jangan return false hanya karena ada scan yang FAILED (422 permanent).
      // Failed scan sudah di-markScanFailed() dan tidak akan muncul lagi
      // di getPendingScans(), jadi tidak perlu blocking.
      final remainingPending = await ApiService.getPendingScansCount();
      return remainingPending == 0;
    } catch (e) {
      print('[SYNC] _doSync error: $e');
      return false;
    }
  }

  static Future<bool> _checkConnection() async {
    try {
      await http
          .get(Uri.parse('${ApiService.baseUrl}/api/health'))
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }
}