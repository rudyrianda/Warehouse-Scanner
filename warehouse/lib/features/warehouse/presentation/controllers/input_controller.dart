import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../../../warehouse/data/datasources/local_database.dart';

class InputController extends ChangeNotifier {
  final GetModelsUseCase getModelsUseCase;

  // final SubmitEntryUseCase submitEntryUseCase;

  InputController({
    required this.getModelsUseCase,
  });

  final bookingCtrl = TextEditingController();
  final contCtrl = TextEditingController();
  final destinationCtrl = TextEditingController();
  final drlCtrl = TextEditingController();
  final doCtrl = TextEditingController();
  final modelCtrl = TextEditingController();
  final qtyCtrl = TextEditingController(text: '1');

  String? _selectedModel;

  String? get selectedModel => _selectedModel;

  String? _selectedProductId;

  String? get selectedProductId => _selectedProductId;

  List<Map<String, dynamic>> _modelData = [];
  List<String> _modelOptions = [];

  List<String> get modelOptions => _modelOptions;

  bool _loadingModels = false;

  bool get loadingModels => _loadingModels;

  final AudioPlayer _player = AudioPlayer();

  int _quantity = 1;

  int get quantity => _quantity;

  bool _submitting = false;

  bool get submitting => _submitting;

  final DateTime selectedDate = DateTime.now();
  final List<Map<String, dynamic>> pendingItems = [];
  final Set<String> submittedTodayModels = {};

  void init() {
    loadModels();
    fetchTodaySubmittedModels();
  }

  @override
  void dispose() {
    bookingCtrl.dispose();
    contCtrl.dispose();
    destinationCtrl.dispose();
    drlCtrl.dispose();
    doCtrl.dispose();
    modelCtrl.dispose();
    qtyCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  void onModelChanged(String? value) {
    if (value == null || value.isEmpty) {
      _selectedModel = null;
      _selectedProductId = null;
      notifyListeners();
      return;
    }

    final found = _modelData.firstWhere(
          (m) => m['productName'] == value,
      orElse: () => <String, dynamic>{'productId': ''},
    );

    _selectedModel = value;
    modelCtrl.text = value;
    _selectedProductId = found['productId']?.toString();
    notifyListeners();
  }

  Future<void> loadModels() async {
    _loadingModels = true;
    notifyListeners();
    try {
      final data = await getModelsUseCase();
      final modelDataList = data
          .map((item) =>
      <String, dynamic>{
        'productName': item['productName'] ?? '',
        'productId': item['productId'] ?? '',
      })
          .toList();
      final seen = <String>{};
      final unique = modelDataList
          .where((m) => seen.add(m['productName']! as String))
          .toList();
      _modelData = unique;
      _modelOptions = unique.map((m) => m['productName']! as String).toList();
    } catch (error) {
      debugPrint('[_loadModels] Error: $error');
      // Fallback ke SQLite lokal
      try {
        final localData = await LocalDatabase.getMasterData();
        final modelDataList = localData
            .map((item) =>
        <String, dynamic>{
          'productName': item['productName'] ?? '',
          'productId': item['productId'] ?? '',
        })
            .toList();
        final seen = <String>{};
        final unique = modelDataList
            .where((m) => seen.add(m['productName']! as String))
            .toList();
        _modelData = unique;
        _modelOptions = unique.map((m) => m['productName']! as String).toList();
      } catch (e) {
        debugPrint('[_loadModels] SQLite fallback error: $e');
      }
    } finally {
      _loadingModels = false;
      notifyListeners();
    }
  }

  Future<void> fetchTodaySubmittedModels() async {
    try {
      final models =
      await LocalDatabase.getTodaySubmittedModels(selectedDate);

      submittedTodayModels.clear();
      submittedTodayModels.addAll(models);

      notifyListeners();
    } catch (e) {
      debugPrint('[_fetchTodaySubmittedModels] Error: $e');
    }
  }

  void adjustQuantity(int delta) {
    _quantity = (_quantity + delta).clamp(1, 9999);
    qtyCtrl.text = '$_quantity';
    notifyListeners();
  }

  void updateQuantityDirect(int value) {
    _quantity = value.clamp(1, 9999);
    qtyCtrl.text = '$_quantity';
    notifyListeners();
  }

  Future<String?> submitEntry() async {
    if (pendingItems.isEmpty) {
      return 'Belum ada item, tekan Enter dulu';
    }
    if (_submitting) return null;
    _submitting = true;
    notifyListeners();
    try {
      await LocalDatabase.saveEntry(
        date: selectedDate,
        containerNumber: contCtrl.text.trim(),
        bookingConfirmation: bookingCtrl.text.trim(),
        items: pendingItems,
      );
      submittedTodayModels.addAll(
        pendingItems.map((item) => item['model'] as String),
      );
      pendingItems.clear();
      await _player.play(AssetSource('SuccessSound.mp3'));
      return null;
    } catch (e) {
      return e.toString();
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }

  Future<bool> onEnter() async {
    final model = modelCtrl.text.trim();
    final destination = destinationCtrl.text.trim();
    final drl = drlCtrl.text.trim();
    final currentDo = doCtrl.text.trim();

    if (model.isEmpty || destination.isEmpty || drl.isEmpty ||
        currentDo.isEmpty) {
      return false;
    }

    String resolvedProductId = _selectedProductId ?? '';
    if (resolvedProductId.isEmpty) {
      final found = _modelData.firstWhere(
            (m) =>
        m['productName']?.toString().toLowerCase() == model.toLowerCase(),
        orElse: () => <String, dynamic>{},
      );
      if (found.isNotEmpty) {
        resolvedProductId = found['productId']?.toString() ?? '';
      }
    }

    pendingItems.add({
      'model': model,
      'contNo': contCtrl.text.trim(),
      'destination': destination,
      'drlNumber': drl,
      //'doText': doCtrl.text.trim(),
      'doText': currentDo,
      'serialNumber': resolvedProductId,
      'quantity': _quantity,
    });

    modelCtrl.clear();
    _quantity = 1;
    qtyCtrl.text = '1';
    _selectedModel = null;
    _selectedProductId = null;
    notifyListeners();
    await _player.play(AssetSource('SuccessSound.mp3'));
    return true;
  }

  void nextDoNumber() {
// Kosongkan field DO agar operator bisa mengetik DO baru
    doCtrl.clear();
// Kosongkan field model jika sempat terisi setengah jalan
    modelCtrl.clear();

    notifyListeners();
  }
}
