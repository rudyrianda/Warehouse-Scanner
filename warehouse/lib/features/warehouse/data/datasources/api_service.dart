import 'dart:convert';
import 'package:http/http.dart' as http;
import 'local_database.dart';
import 'master_data_seed.dart';
import '../../../../core/config/config.dart' as app_config;

class ApiService {
  static const String baseUrl = app_config.apiBaseUrl;
  static const String apiKey = app_config.apiKey;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      };

  // ── Fetch containers hari ini dari server → simpan ke SQLite ──
  static Future<List<Map<String, dynamic>>>
      fetchAndCacheContainersToday() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/containers/today'), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) throw Exception('Server error');

      final List data = jsonDecode(res.body);
      final containers = data.cast<Map<String, dynamic>>();

      for (final c in containers) {
        await LocalDatabase.insertEntryFromServer(
          entryDate: DateTime.now().toIso8601String().substring(0, 10),
          containerNumber: c['containerNumber'],
          bookingConfirmation: c['bookingConfirmation']?.toString(),
          serverId: c['entryId'],
        );
      }

      return containers;
    } catch (_) {
      return await LocalDatabase.getEntries();
    }
  }

  // ── Fetch details container → simpan ke SQLite ──
  static Future<List<Map<String, dynamic>>> fetchAndCacheContainerDetails(
      String containerNumber) async {
    try {
      final res = await http
          .get(
            Uri.parse('$baseUrl/api/containers/$containerNumber/details'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) throw Exception('Server error');

      final List data = jsonDecode(res.body);
      final details = data.cast<Map<String, dynamic>>();

      for (final d in details) {
        final localEntryId = await LocalDatabase.insertEntryFromServer(
          entryDate: DateTime.now().toIso8601String().substring(0, 10),
          containerNumber: containerNumber,
          bookingConfirmation: d['bookingConfirmation']?.toString(),
          serverId: d['entryId'],
        );
        await LocalDatabase.insertDetailFromServer(
          localEntryId: localEntryId,
          serverDetailId: d['detailId'],
          model: d['model'],
          contNo: d['contNo'],
          destination: d['destination'],
          drlNumber: d['drlNumber'],
          doText: d['doText'],
          serialNumber: d['serialNumber'],
          quantity: d['quantity'],
        );
      }

      return details;
    } catch (_) {
      return await LocalDatabase.getDetailsByContainerNumber(containerNumber);
    }
  }

  // ── Scan: validasi lokal dulu, simpan ke SQLite ──
  static Future<Map<String, dynamic>> scanSerial({
    required String serialNumber,
    required String? containerNumber,
    String? doNumber,
  }) async {
    if (containerNumber == null || containerNumber.isEmpty) {
      return {
        'success': false,
        'error': 'Container wajib dipilih sebelum scan'
      };
    }

    final cleaned =
        serialNumber.trimLeft().replaceFirst(RegExp(r'^[^a-zA-Z0-9]+'), '');
    final input = cleaned.isEmpty ? serialNumber.trim() : cleaned;

    final matched = await LocalDatabase.matchSerialPrefix(
      input,
      containerNumber,
      doText: doNumber,
    );

    if (matched == null) {
      final otherContainer = await LocalDatabase.findContainerForSerial(input);
      if (otherContainer != null) {
        return {
          'success': false,
          'error':
              "Serial number ini terdaftar untuk container '$otherContainer', "
                  "bukan untuk container '$containerNumber' yang sedang dipilih."
        };
      }
      return {
        'success': false,
        'error':
            'Serial tidak dikenali. Prefix tidak cocok dengan data apapun untuk hari ini.'
      };
    }

    final matchedDetailId = matched['detailId'] as int;

    final existingDo = await LocalDatabase.checkDuplicateInContainer(
      input,
      containerNumber,
    );

    if (existingDo != null) {
      final currentDo = doNumber;
      final errMsg = existingDo == currentDo 
          ? "Serial '$serialNumber' sudah pernah discan untuk DO/detail ini hari ini."
          : "Serial '$serialNumber' sudah discan di DO yang berbeda ($existingDo) dalam kontainer ini.";
      
      return {
        'success': false,
        'error': errMsg,
      };
    }

    final scannedToday = await LocalDatabase.countScannedToday(matchedDetailId);
    final allowedQty = matched['quantity'] as int? ?? 0;
    if (scannedToday >= allowedQty) {
      return {
        'success': false,
        'error':
            "Qty '${matched['model']}' sudah terpenuhi ($scannedToday/$allowedQty)."
      };
    }

    await LocalDatabase.insertScan(
      entryDetailId: matchedDetailId,
      model: matched['model'] ?? '',
      serialNumber: input,
      contNo: matched['contNo'],
      destination: matched['destination'],
      drlNumber: matched['drlNumber'],
      doText: matched['doText'],
      containerNumber: matched['containerNumber'],
    );

    return {
      'success': true,
      'model': matched['model'],
      'scannedToday': scannedToday + 1,
      'allowedQty': allowedQty,
    };
  }

  // ── Master Data ──
  static Future<void> fetchAndCacheMasterData() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/models'), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) throw Exception('Server error');

      final List data = jsonDecode(res.body);
      final items = data
          .map((e) => {
                'productId': e['Product_Id']?.toString(),
                'marking': e['Marking']?.toString(),
                'productName': e['ProductName']?.toString(),
                'machineCode': e['MachineCode']?.toString(),
                'description': e['Description']?.toString(),
                'prodPlan': e['ProdPlan'],
                'sut': e['SUT'],
                'noOfOperator': e['NoOfOperator'],
                'qtyHour': e['QtyHour'],
                'prodHeadHour': e['ProdHeadHour'],
                'cycleTimeVacum': e['CycleTimeVacum'],
                'workHour': e['WorkHour'],
              })
          .toList();

      await LocalDatabase.insertMasterData(items);
    } catch (_) {
      await LocalDatabase.insertMasterData(MasterDataSeed.data);
    }
  }

  // ══════════════════════════════════════════════════════════════
  // SYNC — urutan wajib: Entry → Detail → ScannedItems
  // ══════════════════════════════════════════════════════════════

  static Future<bool> _syncPendingEntries() async {
    final pending = await LocalDatabase.getPendingEntries();

    for (final entry in pending) {
      try {
        final localEntryId = entry['id'] as int;
        final details = await LocalDatabase.getPendingDetailsByEntryId(localEntryId);

        if (details.isEmpty) {
          print('[SYNC] Entry $localEntryId dilewati — tidak ada EntryDetails pending');
          continue;
        }

        final res = await http
            .post(
              Uri.parse('$baseUrl/api/entries'),
              headers: _headers,
              body: jsonEncode({
                'date': entry['entryDate'],
                'containerNumber': entry['containerNumber'],
                'bookingConfirmation': entry['bookingConfirmation'],
                'items': details
                    .map((d) => {
                          'clientDetailId': d['id'],
                          'model': d['model'],
                          'contNo': d['contNo'],
                          'destination': d['destination'],
                          'drlNumber': d['drlNumber'],
                          'doText': d['doText'],
                          'serialNumber': d['serialNumber'],
                          'quantity': d['quantity'],
                        })
                    .toList(),
              }),
            )
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200 || res.statusCode == 201) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          final serverId = body['entryId'] as int?;

          if (serverId == null) {
            print('[SYNC] ✗ Entry $localEntryId response tidak punya entryId');
            print('[SYNC] BODY : ${res.body}');
            return false;
          }

          await LocalDatabase.markEntrySynced(localEntryId, serverId);

          int mapped = 0;
          if (body['details'] is List) {
            for (final item in body['details'] as List) {
              if (item is! Map) continue;
              final clientDetailId = item['clientDetailId'];
              final serverDetailId = item['detailId'];
              if (clientDetailId is int && serverDetailId is int && serverDetailId > 0) {
                await LocalDatabase.markDetailSynced(clientDetailId, serverDetailId);
                mapped++;
                print('[SYNC] ✓ Detail local=$clientDetailId → serverDetailId=$serverDetailId');
              }
            }
          }

          if (mapped < details.length) {
            print('[SYNC] ⚠ Entry $localEntryId synced, tapi detail mapping belum lengkap ($mapped/${details.length}).');
          } else {
            print('[SYNC] ✓ Entry $localEntryId synced + detail mapping lengkap');
          }

          // JANGAN deleteEntryById di sini.
          // ScannedItems lokal masih membutuhkan EntryDetails lokal untuk mengambil
          // serverDetailId saat sync scan. Cleanup boleh dilakukan setelah semua scan
          // terkait benar-benar synced.
        } else {
          print('[SYNC] ✗ Entry $localEntryId failed');
          print('[SYNC] STATUS : ${res.statusCode}');
          print('[SYNC] BODY   : ${res.body}');
        }
      } catch (e) {
        print('[SYNC ERROR] Exception during entries sync: $e');
        return false;
      }
    }
    return true;
  }

  static Future<void> _syncPendingDetailsByEntry({
    required int localEntryId,
    required int serverEntryId,
  }) async {
    final pending =
        await LocalDatabase.getPendingDetailsByEntryId(localEntryId);

    for (final detail in pending) {
      try {
        final res = await http
            .post(
              Uri.parse('$baseUrl/api/entries/$serverEntryId/details'),
              headers: _headers,
              body: jsonEncode({
                'model': detail['model'],
                'contNo': detail['contNo'],
                'destination': detail['destination'],
                'drlNumber': detail['drlNumber'],
                'doText': detail['doText'],
                'serialNumber': detail['serialNumber'],
                'quantity': detail['quantity'],
              }),
            )
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200 || res.statusCode == 201) {
          final body = jsonDecode(res.body);
          final serverDetailId = body['detailId'] as int;
          await LocalDatabase.markDetailSynced(detail['id'], serverDetailId);
        } else if (res.statusCode == 409) {
          final body = jsonDecode(res.body);
          final serverDetailId = body['detailId'] as int;
          await LocalDatabase.markDetailSynced(detail['id'], serverDetailId);
        } else {
          print('[SYNC] Detail ${detail['id']} failed');
          print('[SYNC] STATUS : ${res.statusCode}');
          print('[SYNC] BODY   : ${res.body}');
        }
      } catch (e) {
        print('[SYNC ERROR] $e');
        break;
      }
    }
  }

  static Future<SyncResult> _syncPendingScans() async {
    final pending = await LocalDatabase.getPendingScans();
    print('[SYNC] Pending scans ditemukan: ${pending.length}');

    // ── DIAGNOSTIC: dump semua pending scan sebelum proses sync ───────────
    print('[SYNC] ══════════════════════════════════════════');
    print('[SYNC] Total pending: ${pending.length} scan(s)');
    for (final s in pending) {
      final localDb2 = await LocalDatabase.db;
      final dRows = await localDb2.query('EntryDetails',
          where: 'id = ?', whereArgs: [s['entryDetailId']]);
      final svrId = dRows.isNotEmpty ? dRows.first['serverDetailId'] : 'N/A';
      final doTxt = dRows.isNotEmpty ? dRows.first['doText'] : 'N/A';
      print(
          '[SYNC]  id=${s['id']} serial=${s['serialNumber']} doText=${s['doText']} '
          'entryDetailId=${s['entryDetailId']} serverDetailId=$svrId detailDoText=$doTxt');
    }
    print('[SYNC] ══════════════════════════════════════════');

    int success = 0, failed = 0;
    for (final scan in pending) {
      final id = scan['id'];
      try {
        // FIX: ambil serverDetailId dari EntryDetails supaya backend bisa
        // langsung pakai DetailId yang tepat tanpa harus prefix-match ulang.
        // Ini kritis untuk kasus 2 DO beda tapi prefix serialNumber sama.
        int? serverDetailId;
        try {
          final localDb = await LocalDatabase.db;
          final detailRows = await localDb.query(
            'EntryDetails',
            columns: ['serverDetailId'],
            where: 'id = ?',
            whereArgs: [scan['entryDetailId']],
          );
          serverDetailId = detailRows.isNotEmpty
              ? detailRows.first['serverDetailId'] as int?
              : null;
        } catch (_) {
          serverDetailId = null;
        }

        final body = <String, dynamic>{
          'serialNumber': scan['serialNumber'],
          'containerNumber': scan['containerNumber'],
          'doText': scan['doText'],
        };
        if (serverDetailId != null) body['serverDetailId'] = serverDetailId;

        print(
            '[SYNC] → Scan $id: serial=${scan['serialNumber']} doText=${scan['doText']} serverDetailId=$serverDetailId');

        final res = await http
            .post(
              Uri.parse('$baseUrl/api/scan'),
              headers: _headers,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final serverItemId = body['id'] as int?;
          await LocalDatabase.markScanSynced(id, serverItemId);
          await LocalDatabase.deleteScan(id);
          success++;

          print(
              '[SYNC] ✓ Scan $id synced (serverItemId=$serverItemId) & deleted');
        } else if (res.statusCode == 409) {
          await LocalDatabase.markScanSynced(id, null);
          await LocalDatabase.deleteScan(id);
          success++;
          print(
              '[SYNC] ✓ Scan $id already in server (409), deleted from local');
          print(
              "[SYNC] 409 DATA: serial=${scan['serialNumber']} container=${scan['containerNumber']} doText=${scan['doText']}");
        } else if (res.statusCode == 400 || res.statusCode == 422) {
          failed++;
          await LocalDatabase.markScanFailed(id);
          print('[SYNC] ✗ Scan $id permanent error (${res.statusCode})');
          print('[SYNC] BODY: ${res.body}');
        } else {
          failed++;
          await LocalDatabase.markScanFailed(id);
          print('[SYNC] ✗ Scan $id error: ${res.statusCode}');
          print('[SYNC] BODY: ${res.body}');
        }
      } catch (e) {
        failed++;
        print('[SYNC ERROR] Exception on scan $id: $e');
        continue;
      }
    }

    return SyncResult(success: success, failed: failed);
  }

  static Future<SyncResult> syncAll() async {
    print('[SYNC] ═════════════════════════════════════════');
    print('[SYNC] Mulai sync semua pending data...');
    print('[SYNC] ═════════════════════════════════════════');

    final entriesSynced = await _syncPendingEntries();
    if (!entriesSynced) {
      print('[SYNC] ✗ Gagal sync entries (offline?)');
      print('[SYNC] ═════════════════════════════════════════');
      return SyncResult(success: 0, failed: 0);
    }

    print('[SYNC] ✓ Entries done, mulai sync scans...');

    final result = await _syncPendingScans();

    print('[SYNC] ═════════════════════════════════════════');
    print(
        '[SYNC] Selesai. Success: ${result.success}, Failed: ${result.failed}');
    print('[SYNC] ═════════════════════════════════════════');

    return result;
  }

  static Future<SyncResult> syncPendingScans() => _syncPendingScans();

  /// Hitung jumlah scan yang masih pending di SQLite lokal
  static Future<int> getPendingScansCount() async {
    final pending = await LocalDatabase.getPendingScans();
    return pending.length;
  }
}

class SyncResult {
  final int success;
  final int failed;
  SyncResult({required this.success, required this.failed});
}
