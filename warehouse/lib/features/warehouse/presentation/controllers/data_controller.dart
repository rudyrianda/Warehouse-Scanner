import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../domain/entities/scanned_item.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../../data/datasources/sync_service.dart';

class DataController extends ChangeNotifier {
  final ManageScanUseCase manageScanUseCase;

  DataController({required this.manageScanUseCase});

  final AudioPlayer _errorPlayer = AudioPlayer();

  final scanCtrl = TextEditingController();
  final scanFocus = FocusNode();

  List<ScannedItem> _items = [];
  List<ScannedItem> get items => _items;

  String? _lastMsg;
  String? get lastMsg => _lastMsg;

  bool _lastSuccess = true;
  bool get lastSuccess => _lastSuccess;

  Timer? _debounce;

  String? _selectedContainer;
  String? get selectedContainer => _selectedContainer;

  String? _selectedDo;
  String? get selectedDo => _selectedDo;

  // ── Unique DO dari containerDetails (bukan containers) ───────────────────
  // _containers hanya punya containerNumber + entryId, TIDAK ada doText.
  // doText ada di _containerDetails (hasil getContainerDetails).
  List<String> get uniqueDosInContainer {
    if (_containerDetails.isEmpty) return [];
    final dos = _containerDetails
        .map((d) => d['doText']?.toString() ?? '')
        .where((doNo) => doNo.isNotEmpty)
        .toSet()
        .toList()
      ..sort(); // urutkan A-Z supaya konsisten
    return dos;
  }

  List<Map<String, dynamic>> _containers = [];
  List<Map<String, dynamic>> get containers => _containers;

  List<Map<String, dynamic>> _containerDetails = [];
  List<Map<String, dynamic>> get containerDetails => _containerDetails;

  // ── Container details difilter berdasarkan DO terpilih ───────────────────
  List<Map<String, dynamic>> get containerDetailsByDo {
    if (_selectedDo == null) return _containerDetails;
    return _containerDetails.where((d) {
      final doDet = d['doText']?.toString() ?? '';
      return doDet.isEmpty || doDet == _selectedDo;
    }).toList();
  }

  bool _loadingContainers = false;
  bool get loadingContainers => _loadingContainers;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  // ── filteredItems: filter DO → filter search ──────────────────────────────
  List<ScannedItem> get filteredItems {
    var result = _items;

    if (_selectedDo != null) {
      result = result.where((i) {
        final itemDo = i.doText ?? i.doNo ?? '';
        return itemDo.isEmpty || itemDo == _selectedDo;
      }).toList();
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((i) =>
      (i.serialNumber ?? '').toLowerCase().contains(q) ||
          (i.model ?? '').toLowerCase().contains(q),
      ).toList();
    }

    return result;
  }

  int get scannedCountForSelectedDo {
    if (_selectedDo == null) return _items.length;
    return _items.where((i) {
      final itemDo = i.doText ?? i.doNo ?? '';
      return itemDo == _selectedDo;
    }).length;
  }

  void onSearchChanged(String val) {
    _searchQuery = val;
    notifyListeners();
  }

  void clearSearch() {
    _searchQuery = '';
    notifyListeners();
  }

  int? _lastStatusCode;
  int? get lastStatusCode => _lastStatusCode;

  void init() {
    loadToday();
    loadContainers();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _errorPlayer.dispose();
    scanCtrl.dispose();
    scanFocus.dispose();
    super.dispose();
  }

  // ── Pilih container: sync dulu 1x, lalu load details → load today ───────
  void selectContainer(String? container) {
    _selectedContainer = container;
    _selectedDo = null;
    _containerDetails = [];
    _items = [];
    _searchQuery = '';
    notifyListeners();
    if (container != null) {
      // Urutan PENTING:
      // 1. syncNow() — flush semua offline scan ke server
      // 2. loadContainerDetails — ambil scannedToday dari server (sudah updated)
      // 3. loadToday — ambil list scan dari server
      SyncService.syncNow().then((_) {
        loadContainerDetails(container).then((_) => loadToday());
      });
    }
  }

  // ── Pilih DO: filteredItems + containerDetailsByDo otomatis ikut ─────────
  void selectDo(String? doNumber) {
    _selectedDo = doNumber;
    _searchQuery = '';
    notifyListeners();
    // Reload items agar doText ter-filter dengan benar setelah ganti DO
    if (_selectedContainer != null) loadToday();
  }

  Future<void> loadContainers() async {
    _loadingContainers = true;
    notifyListeners();
    try {
      _containers = await manageScanUseCase.getContainersToday();
    } catch (_) {
      _containers = [];
    } finally {
      _loadingContainers = false;
      notifyListeners();
    }
  }

  Future<void> loadContainerDetails(String containerNumber) async {
    try {
      // Tidak perlu syncNow() di sini karena selectContainer sudah memanggil sync
      // sebelum loadContainerDetails. Kalau dipanggil langsung (bukan via selectContainer),
      // gunakan data lokal sebagai fallback — sudah cukup untuk tampilkan badge.
      _containerDetails =
          await manageScanUseCase.getContainerDetails(containerNumber);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadToday() async {
    try {
      // Sync sudah dijalankan oleh selectContainer/doScan sebelum loadToday.
      // Di sini cukup ambil data dari server tanpa sync ulang.
      if (_selectedContainer != null) {
        _items =
            await manageScanUseCase.getScannedByContainer(_selectedContainer!);
      } else {
        _items = [];
      }
      notifyListeners();
    } catch (_) {}
  }

  void onScanChanged(String val) {
    _debounce?.cancel();
    if (val.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 300), () => doScan());
  }

  void submitScan() {
    _debounce?.cancel();
    doScan();
  }

  Future<int?> doScan() async {
    final serial = scanCtrl.text.trim();
    if (serial.isEmpty) return null;

    if (_selectedContainer == null) {
      _lastMsg = 'Pilih container terlebih dahulu!';
      _lastSuccess = false;
      _lastStatusCode = 400;
      notifyListeners();
      await _errorPlayer.play(AssetSource('ErrorSound.mp3'));
      scanFocus.requestFocus();
      return 400;
    }

    if (_selectedDo == null) {
      _lastMsg = 'Pilih DO Number terlebih dahulu!';
      _lastSuccess = false;
      _lastStatusCode = 400;
      notifyListeners();
      await _errorPlayer.play(AssetSource('ErrorSound.mp3'));
      scanFocus.requestFocus();
      return 400;
    }

    try {
      final body = await manageScanUseCase.scan(
        serial,
        _selectedContainer!,
        doNumber: _selectedDo!,
      );

      _lastMsg = '✓ ${body['message']} — ${body['model']}';
      _lastSuccess = true;
      _lastStatusCode = 200;
      scanCtrl.clear();
      notifyListeners();
      await loadToday();
      if (_selectedContainer != null) {
        await loadContainerDetails(_selectedContainer!);
      }
      scanFocus.requestFocus();
      return 200;
    } catch (e) {
      scanCtrl.clear();

      if (e is http.Response) {
        _lastMsg = e.body.contains('"error"')
            ? (e.body.split('"error":"')[1].split('"')[0])
            : 'Error';
        _lastSuccess = false;
        _lastStatusCode = e.statusCode;

        if (e.statusCode == 409 || e.statusCode == 422 || e.statusCode == 400) {
          notifyListeners();
          await _errorPlayer.play(AssetSource('ErrorSound.mp3'));
        } else {
          notifyListeners();
          scanFocus.requestFocus();
        }
        return e.statusCode;
      } else {
        _lastMsg = 'Koneksi gagal: $e';
        _lastSuccess = false;
        _lastStatusCode = 500;
        notifyListeners();
        scanFocus.requestFocus();
        return 500;
      }
    }
  }

  void onErrorDialogClosed() {
    _lastStatusCode = null;
    scanFocus.requestFocus();
  }

  Future<void> deleteItem(int id) async {
    await manageScanUseCase.deleteScan(id);
    await loadToday();
    if (_selectedContainer != null) {
      await loadContainerDetails(_selectedContainer!);
    }
  }

  Future<void> editItem(int id, String serialNumber, int quantity) async {
    await manageScanUseCase.updateScan(id,
        serialNumber: serialNumber, quantity: quantity);
    await loadToday();
    if (_selectedContainer != null) {
      await loadContainerDetails(_selectedContainer!);
    }
  }

  void refreshAll() {
    loadToday();
    loadContainers();
    if (_selectedContainer != null) {
      loadContainerDetails(_selectedContainer!);
    }
  }
}
