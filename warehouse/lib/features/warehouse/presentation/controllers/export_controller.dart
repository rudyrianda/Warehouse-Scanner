import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../../data/datasources/sync_service.dart';
import '../../data/datasources/local_database.dart';

class ExportController extends ChangeNotifier {
  final ExportDataUseCase exportDataUseCase;

  ExportController({required this.exportDataUseCase});

  bool _loading = false;
  bool get loading => _loading;

  DateTime _selectedDate = DateTime.now();
  DateTime get selectedDate => _selectedDate;

  final List<String> _progressLog = [];
  List<String> get progressLog => List.unmodifiable(_progressLog);

  final List<Map<String, dynamic>> _bookingStatus = [];
  List<Map<String, dynamic>> get bookingStatus =>
      List.unmodifiable(_bookingStatus);

  String? _currentProcessing;
  String? get currentProcessing => _currentProcessing;

  void updateDate(DateTime picked) {
    _selectedDate = picked;
    notifyListeners();
  }

  void _log(String msg) {
    _progressLog.add(msg);
    notifyListeners();
  }

  void _setStatus(String booking, String status) {
    final idx = _bookingStatus.indexWhere((e) => e['booking'] == booking);
    if (idx != -1) {
      _bookingStatus[idx] = {
        'booking': booking,
        'status': status,
      };
    }
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> exportAll({bool forceExport = false}) async {
    _loading = true;
    _progressLog.clear();
    _bookingStatus.clear();
    _currentProcessing = null;
    notifyListeners();

    final results = <Map<String, dynamic>>[];

    try {
      // 1. Permissions
      if (Platform.isAndroid) {
        if (await Permission.manageExternalStorage.status.isDenied) {
          await Permission.manageExternalStorage.request();
        }
        if (await Permission.storage.status.isDenied) {
          await Permission.storage.request();
        }
      }

      // 2. Force sync dulu — pastikan semua pending scan sudah masuk SQL
      //    sebelum export dibuat. Tanpa ini, scan offline yang baru saja
      //    terhubung internet bisa belum tersinkron saat export dibaca.
      _log('🔄 Menyinkronkan data pending ke server...');
      try {
        final syncSuccess = await SyncService.syncNow();
        if (syncSuccess) {
          _log('✅ Sync selesai.');
        } else {
          // Cek apakah hanya ada scan 'failed' (permanent error) yang tersisa,
          // atau masih ada 'pending' yang belum dicoba.
          final pendingCount = await _getPendingScanCount();
          final failedCount = await _getFailedScanCount();

          if (pendingCount > 0) {
            // Masih ada scan pending yang belum dicoba — tunggu sync selesai
            _log('❌ Sync gagal / masih ada $pendingCount scan pending. Export dibatalkan.');
            _loading = false;
            notifyListeners();
            return [
              {
                'container': '-',
                'success': false,
                'message': 'Sync gagal atau masih ada scan pending. Coba sync ulang dulu sebelum export.',
              }
            ];
          } else if (failedCount > 0) {
            // Hanya scan failed (permanent error, mis. 422 "Quantity sudah terpenuhi")
            // yang tersisa. Ini tidak akan pernah berhasil di-retry, jadi lanjutkan export.
            _log('⚠️ Ada $failedCount scan gagal permanen (ditolak server). '
                'Scan ini akan dihapus dari antrian. Export tetap dilanjutkan.');
            // Hapus failed scans agar tidak menumpuk
            await _clearFailedScans();
          }
        }
      } catch (e) {
        _log('⚠️ Sync error: $e');
      }

      // 3. Ambil daftar booking hari ini
      _log('🔍 Mengambil daftar Booking Confirmation...');
      final bookings = await exportDataUseCase.getBookingsToday();

      if (bookings.isEmpty) {
        _log('⚠️ Tidak ada Booking Confirmation hari ini.');
        _loading = false;
        notifyListeners();
        return [{
          'booking': '-',
          'success': false,
          'message': 'Tidak ada data untuk tanggal '
              '${DateFormat('dd-MM-yyyy').format(_selectedDate)}.',
        }];
      }

      // 4. Bangun checklist per booking (1 file per booking)
      for (final b in bookings) {
        final bNo = b['bookingConfirmation']?.toString() ?? '';
        if (bNo.isEmpty) continue;
        _bookingStatus.add({
          'booking': bNo,
          'status': 'pending',
        });
      }
      notifyListeners();

      // --- DUPLICATE INTERCEPTION LOGIC ---
      if (!forceExport) {
        _log('🔍 Memeriksa potensi duplikat...');
        final duplicates = <String>[];
        
        for (final target in _bookingStatus) {
          final bookingConfirmation = target['booking'] as String? ?? '';
          if (bookingConfirmation.isEmpty) continue;
          
          final data = await exportDataUseCase.getExportData(
            _selectedDate,
            bookingConfirmation: bookingConfirmation,
          );
          
          for (final row in data) {
            final warning = row['warningText']?.toString() ?? '';
            final serial = row['serialNumber']?.toString() ?? '-';
            final doText = row['doText']?.toString() ?? '-';
            
            if (warning.isNotEmpty) {
              final flatWarning = warning.replaceAll('\n', ' ');
              duplicates.add('Serial: $serial\n(DO: $doText)\n$flatWarning\n');
            }
          }
        }
        
        if (duplicates.isNotEmpty) {
          _loading = false;
          notifyListeners();
          return [{
            'requiresConfirmation': true,
            'duplicates': duplicates,
          }];
        }
      }
      // --- END DUPLICATE INTERCEPTION LOGIC ---

      // 5. Folder simpan lokal
      Directory saveDir;
      if (Platform.isAndroid) {
        final dlDir = Directory('/storage/emulated/0/Download');
        saveDir = await dlDir.exists()
            ? dlDir
            : (await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory());
      } else {
        saveDir = await getApplicationDocumentsDirectory();
      }

      final fileDate = DateFormat('MM-dd-yyyy').format(_selectedDate);

      // 6. Loop tiap Booking — 1 file Excel per booking
      for (final target in _bookingStatus) {
        final bookingConfirmation = target['booking'] as String? ?? '';
        if (bookingConfirmation.isEmpty) continue;

        _currentProcessing = bookingConfirmation;
        _setStatus(bookingConfirmation, 'processing');
        _log('📦 Memproses booking: $bookingConfirmation...');

        try {
          // ✅ FIX: Ambil SEMUA data booking
          final data = await exportDataUseCase.getExportData(
            _selectedDate,
            bookingConfirmation: bookingConfirmation,
          );

          if (data.isEmpty) {
            _log('  ⚠️ $bookingConfirmation: tidak ada data scan.');
            _setStatus(bookingConfirmation, 'failed');
            results.add({
              'booking': bookingConfirmation,
              'success': false,
              'message': 'Tidak ada data scan untuk booking ini.',
            });
            continue;
          }

          // ✅ FIX: Semua DO masuk ke 1 file Excel
          //    Data sudah diurutkan berdasarkan DoText dari backend
          //    sehingga baris per-DO akan berkelompok rapi
          final excel = Excel.createExcel();
          final sheet = excel['Sheet1'];

          // Header
          final hasAnyWarning = data.any((r) => (r['warningText']?.toString() ?? '').isNotEmpty);

          final colHeaders = [
            'Date', 'Prod.Date', 'City', 'Port Destination', 'Booking Confirmation', 'DRL Number',
            'Serial Number', 'Model', 'DO', 'Container No', 
            if (hasAnyWarning) 'Warning'
          ];
          for (var i = 0; i < colHeaders.length; i++) {
            sheet
                .cell(CellIndex.indexByColumnRow(
                columnIndex: i, rowIndex: 0))
              ..value = TextCellValue(colHeaders[i])
              ..cellStyle = CellStyle(bold: true);
          }

          // ✅ FIX: Tulis SEMUA baris (semua DO) ke sheet yang sama
          for (var ri = 0; ri < data.length; ri++) {
            final row = data[ri];
            final warningTxt = row['warningText']?.toString() ?? '';
            final hasWarning = warningTxt.isNotEmpty;
            
            final cityData = row['city']?.toString() ?? '';
            
            // Konversi nama kota menjadi singkatan (Case-Insensitive & Anti-Spasi)
            final String tempCode = cityData.toUpperCase().replaceAll(' ', '');
            String cityCode;
            
            if (tempCode == 'HOCHIMINH') {
              cityCode = 'HCM';
            } else if (tempCode == 'DANANG') {
              cityCode = 'DN';
            } else if (tempCode == 'HAIPHONG') {
              cityCode = 'HAIPHONG';
            } else {
              cityCode = cityData; // Jika bukan ketiganya, pakai nama aslinya
            }
            
            final portDestination = cityData.isNotEmpty ? '045DX14518-$cityCode' : '';            
            final values = [
              row['date'],
              row['prodDate'], // Prod.Date from Backend
              cityData,
              portDestination,
              row['bookingConfirmation'], // Added Booking Confirmation
              row['drlNumber'],
              row['serialNumber'],
              row['model'],
              row['doText'],      // kolom DO — setiap baris punya DO masing-masing
              row['containerNo'],
              if (hasAnyWarning) warningTxt,         // kolom Warning (opsional)
            ];
            
            for (var ci = 0; ci < values.length; ci++) {
              final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: ci, rowIndex: ri + 1));
              cell.value = TextCellValue(values[ci]?.toString() ?? '');
              
              if (hasWarning) {
                // Beri warna background merah/kuning pada SELURUH SEL di baris ini
                cell.cellStyle = CellStyle(
                  backgroundColorHex: ExcelColor.yellow,
                );
              }
            }
          }

          // ✅ FIX: Nama file per booking
          final fileName = '${bookingConfirmation}_Warehouse_$fileDate.xlsx';
          final filePath = '${saveDir.path}/$fileName';
          final fileBytes = excel.encode()!;

          // Simpan lokal
          await File(filePath).writeAsBytes(fileBytes);
          _log('  💾 Tersimpan lokal: $filePath (${data.length} baris)');

          // ✅ Hitung ringkasan DO untuk log
          final doSummary = <String, int>{};
          for (final row in data) {
            final doKey = row['doText']?.toString() ?? '-';
            doSummary[doKey] = (doSummary[doKey] ?? 0) + 1;
          }
          for (final entry in doSummary.entries) {
            _log('     DO ${entry.key}: ${entry.value} baris');
          }

          // Upload ke shared folder via backend
          try {
            await exportDataUseCase.uploadFile(fileBytes, fileName);
            _log('  ☁️ Upload berhasil: $fileName');
            _setStatus(bookingConfirmation, 'success');
            results.add({
              'booking': bookingConfirmation,
              'success': true,
              'message': '$fileName\n'
                  '${data.length} baris total • '
                  '${doSummary.length} DO: ${doSummary.keys.join(', ')}',
            });
          } catch (uploadError) {
            _log('  ❌ Upload gagal: $uploadError');
            _setStatus(bookingConfirmation, 'failed');
            results.add({
              'booking': bookingConfirmation,
              'success': false,
              'message': 'File tersimpan lokal tapi upload ke server gagal.\n'
                  'Error: $uploadError',
            });
          }
        } catch (e) {
          _log('  ❌ $bookingConfirmation: $e');
          _setStatus(bookingConfirmation, 'failed');
          results.add({
            'booking': bookingConfirmation,
            'success': false,
            'message': e.toString(),
          });
        }
      }
    } catch (e) {
      _log('❌ Error umum: $e');
      results.add({
        'booking': '-',
        'success': false,
        'message': e.toString(),
      });
    }

    _currentProcessing = null;
    _loading = false;
    notifyListeners();
    return results;
  }

  // ── Helper methods untuk cek status scan ──────────────────────

  Future<int> _getPendingScanCount() async {
    final pending = await LocalDatabase.getPendingScans();
    return pending.length;
  }

  Future<int> _getFailedScanCount() async {
    return await LocalDatabase.getFailedScansCount();
  }

  Future<void> _clearFailedScans() async {
    await LocalDatabase.clearFailedScans();
  }
}