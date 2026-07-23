import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../../../core/config/config.dart';
import '../models/scanned_item_model.dart';
import '../models/entry_detail_model.dart';
import 'local_database.dart';
import 'api_service.dart';

class WarehouseRemoteDataSource {
  final http.Client client;

  WarehouseRemoteDataSource({required this.client});

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'x-api-key': apiKey,
  };

  // ─────────────────────────────────────────────
  // MODELS
  // ─────────────────────────────────────────────

  Future<List<Map<String, String>>> getModels() async {
    final response = await client.get(
      Uri.parse('$apiBaseUrl/api/models'),
      headers: {'x-api-key': apiKey},
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as List<dynamic>;
      return data
          .where((item) => item['productName'] != null)
          .map((item) => {
        'productName': item['productName']?.toString().trim() ?? '',
        'productId': (item['product_Id'] ??
            item['Product_Id'] ??
            item['productId'] ??
            '')
            .toString()
            .trim(),
      })
          .toList();
    } else {
      throw Exception('Gagal load models: ${response.statusCode}');
    }
  }

  Future<List<String>> getTodaySubmittedModels(String dateStr) async {
    final entriesResp = await client.get(
      Uri.parse('$apiBaseUrl/api/entries'),
      headers: {'x-api-key': apiKey},
    ).timeout(const Duration(seconds: 10));

    if (entriesResp.statusCode != 200) return [];

    final entries = jsonDecode(entriesResp.body) as List<dynamic>;
    final todayEntries = entries
        .where((e) => (e['entryDate'] as String?)?.startsWith(dateStr) == true)
        .toList();

    final models = <String>{};
    for (final entry in todayEntries) {
      final entryId = entry['entryId'];
      final detailResp = await client.get(
        Uri.parse('$apiBaseUrl/api/entries/$entryId/details'),
        headers: {'x-api-key': apiKey},
      ).timeout(const Duration(seconds: 10));
      if (detailResp.statusCode == 200) {
        final details = jsonDecode(detailResp.body) as List<dynamic>;
        for (final d in details) {
          final m = d['model']?.toString().trim();
          if (m != null && m.isNotEmpty) models.add(m);
        }
      }
    }
    return models.toList();
  }

  // ─────────────────────────────────────────────
  // ENTRIES
  // ─────────────────────────────────────────────

  /// Hybrid — online POST, fallback simpan ke SQLite lokal
  Future<void> submitEntry({
    required String dateIso,
    required String containerNumber,
    required String? bookingConfirmation,
    required List<Map<String, dynamic>> items,
  }) async {
    try {
      final response = await client.post(
        Uri.parse('$apiBaseUrl/api/entries'),
        headers: _headers,
        body: jsonEncode({
          'entryDate': dateIso,
          'containerNumber': containerNumber,
          'bookingConfirmation': bookingConfirmation,
          'details': items,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        return;
      }

      throw Exception('Server error: ${response.statusCode}');
    } catch (_) {
      // Fallback offline — simpan ke SQLite
      final localEntryId = await LocalDatabase.insertEntryLocal(
        entryDate: dateIso.substring(0, 10),
        containerNumber: containerNumber,
        bookingConfirmation: bookingConfirmation,
      );

      for (final item in items) {
        await LocalDatabase.insertDetailLocal(
          localEntryId: localEntryId,
          model: item['model'],
          contNo: item['contNo'],
          destination: item['destination'],
          drlNumber: item['drlNumber'],
          doText: item['doText'],
          serialNumber: item['serialNumber'],
          quantity: item['quantity'],
        );
      }
    }
  }

  /// Hybrid — fetch online, fallback ke SQLite lokal
  Future<List<EntryDetailModel>> fetchEntriesForDate(String dateStr) async {
    try {
      final entriesResp = await client.get(
        Uri.parse('$apiBaseUrl/api/entries'),
        headers: {'x-api-key': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (entriesResp.statusCode != 200) throw Exception('Server error');

      final entries = jsonDecode(entriesResp.body) as List<dynamic>;

      final filtered = entries
          .where((e) =>
      (e['entryDate'] as String?)?.startsWith(dateStr) == true)
          .toList();

      if (filtered.isEmpty) return [];

      final allDetails = <EntryDetailModel>[];

      for (final entry in filtered) {
        final entryId = entry['entryId'] as int;

        final detailResp = await client.get(
          Uri.parse('$apiBaseUrl/api/entries/$entryId/details'),
          headers: {'x-api-key': apiKey},
        ).timeout(const Duration(seconds: 10));

        if (detailResp.statusCode == 200) {
          final details = jsonDecode(detailResp.body) as List<dynamic>;
          for (final d in details) {
            allDetails.add(
              EntryDetailModel.fromJson({
                ...Map<String, dynamic>.from(d as Map),
                'entryId': entryId,
              }),
            );
          }
        }
      }

      return allDetails;
    } catch (_) {
      // Fallback offline — ambil dari SQLite
      final details = await LocalDatabase.queryTable('EntryDetails');
      return details.map((e) => EntryDetailModel.fromJson(e)).toList();
    }
  }

  /// Hybrid — online PUT, fallback update SQLite dengan syncStatus pending
  Future<void> updateEntryDetail(
      int detailId, Map<String, dynamic> payload) async {
    try {
      final response = await client.put(
        Uri.parse('$apiBaseUrl/api/details/$detailId'),
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) throw Exception('Server error');
    } catch (_) {
      // Fallback offline — tandai pending di SQLite
      final database = await LocalDatabase.db;
      await database.update(
        'EntryDetails',
        {...payload, 'syncStatus': 'pending'},
        where: 'id = ?',
        whereArgs: [detailId],
      );
    }
  }

  // ─────────────────────────────────────────────
  // CONTAINERS
  // ─────────────────────────────────────────────

  /// Hybrid — fetch online + cache ke SQLite, fallback baca SQLite
  Future<List<Map<String, dynamic>>> getContainersToday() async {
    try {
      final response = await client.get(
        Uri.parse('$apiBaseUrl/api/containers/today'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        final containers =
        data.map((e) => Map<String, dynamic>.from(e as Map)).toList();

        // Cache ke SQLite
        for (final c in containers) {
          await LocalDatabase.insertEntryFromServer(
            entryDate:
            DateTime.now().toIso8601String().substring(0, 10),
            containerNumber: c['containerNumber'],
            bookingConfirmation: c['bookingConfirmation']?.toString(),
            serverId: c['entryId'],
          );
        }
        return containers;
      }
      throw Exception('Server error');
    } catch (_) {
      // Fallback offline — baca dari SQLite
      final entries = await LocalDatabase.getEntries();
      return entries
          .map((e) => {
        'containerNumber': e['containerNumber'],
        'entryId': e['serverId'] ?? e['id'],
      })
          .toList();
    }
  }

  Future<List<Map<String, dynamic>>> getBookingsToday() async {
    try {
      final response = await client.get(
        Uri.parse('$apiBaseUrl/api/bookings/today'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Hybrid — fetch online, fallback SQLite per containerNumber
  Future<List<Map<String, dynamic>>> getContainerDetails(
      String containerNumber) async {
    try {
      final response = await client.get(
        Uri.parse(
            '$apiBaseUrl/api/containers/${Uri.encodeComponent(containerNumber)}/details'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        return data
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      throw Exception('Server error');
    } catch (_) {
      // Fallback offline
      return await LocalDatabase.getDetailsByContainerNumber(
          containerNumber);
    }
  }

  // ─────────────────────────────────────────────
  // SCAN
  // ─────────────────────────────────────────────

  /// Hybrid — fetch online, lalu gabungkan dengan scan lokal yang masih pending/failed.
  ///
  /// Kenapa harus digabung?
  /// Saat offline, scan tersimpan di SQLite. Ketika online, halaman Data biasanya
  /// membaca dari SQL Server lewat /api/report. Kalau ada scan lokal yang gagal
  /// sync, data itu terlihat seperti hilang. Dengan merge ini, user tetap bisa
  /// melihat scan pending/failed sampai sync benar-benar berhasil.
  Future<List<ScannedItemModel>> getScannedByContainer(
      String containerNumber) async {
    List<ScannedItemModel> serverItems = [];

    try {
      final today = DateTime.now();
      final dateStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      final response = await client.get(
        Uri.parse(
            '$apiBaseUrl/api/report?date=$dateStr&containerNumber=${Uri.encodeComponent(containerNumber)}'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        serverItems = data.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return ScannedItemModel(
            id: m['id'] as int,
            model: m['model'] as String?,
            serialNumber: m['serialNumber'] as String?,
            quantity: (m['scannedOnDay'] ?? m['quantity']) as int,
            allowedQty: m['allowedQty'] as int,
            scannedAt: m['scannedAt'] as String?,
            doText: m['doText'] as String?,
            doNo: m['doNo'] as String?,
          );
        }).toList();
      } else {
        throw Exception('Server error');
      }
    } catch (_) {
      // Kalau server gagal, tetap fallback full ke SQLite lokal.
      final scanned = await LocalDatabase.getScannedToday();
      return scanned
          .where((s) => s['containerNumber'] == containerNumber)
          .map((s) => ScannedItemModel(
        id: s['id'] as int,
        model: s['model'] as String?,
        serialNumber: s['serialNumber'] as String?,
        quantity: s['scannedCount'] as int? ?? 1,
        allowedQty: s['allowedQty'] as int? ?? 0,
        scannedAt: s['scannedAt'] as String?,
        doText: s['doText'] as String?,
        doNo: s['doNo'] as String?,
      ))
          .toList();
    }

    // Server berhasil. Tetap cek SQLite untuk scan pending/failed yang belum masuk SQL.
    final localRows = await LocalDatabase.getScannedToday();

    final existingKeys = serverItems
        .map((x) => '${x.serialNumber ?? ''}|${x.doText ?? ''}')
        .toSet();

    final merged = [...serverItems];

    for (final s in localRows.where((r) => r['containerNumber'] == containerNumber)) {
      final status = s['syncStatus']?.toString();
      if (status == 'synced' || status == 'failed') continue;

      final serial = s['serialNumber']?.toString() ?? '';
      final doText = s['doText']?.toString() ?? '';
      final key = '$serial|$doText';

      // Kalau server sudah punya serial+DO yang sama, jangan tampilkan dobel.
      if (existingKeys.contains(key)) continue;

      merged.add(ScannedItemModel(
        id: s['id'] as int,
        model: s['model'] as String?,
        serialNumber: s['serialNumber'] as String?,
        quantity: s['scannedCount'] as int? ?? 1,
        allowedQty: s['allowedQty'] as int? ?? 0,
        scannedAt: s['scannedAt'] as String?,
        doText: s['doText'] as String?,
        doNo: s['doNo'] as String?,
      ));
      existingKeys.add(key);
    }

    return merged;
  }


  /// Hybrid — fetch online, fallback SQLite
  Future<List<ScannedItemModel>> getScannedToday() async {
    try {
      final response = await client.get(
        Uri.parse('$apiBaseUrl/api/scan/today'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        return data
            .map((e) =>
            ScannedItemModel.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      throw Exception('Server error');
    } catch (_) {
      // Fallback offline
      final scanned = await LocalDatabase.getScannedToday();
      return scanned
          .map((s) => ScannedItemModel(
        id: s['id'] as int,
        model: s['model'] as String?,
        serialNumber: s['serialNumber'] as String?,
        quantity: s['scannedCount'] as int? ?? 1,
        allowedQty: s['allowedQty'] as int? ?? 0,
        scannedAt: s['scannedAt'] as String?,
      ))
          .toList();
    }
  }

  /// FIX: tambah parameter doNumber dan teruskan ke ApiService.scanSerial
  Future<Map<String, dynamic>> scanSerialNumber(
      String serialNumber,
      String containerNumber, {
        String? doNumber,
      }) async {
    final result = await ApiService.scanSerial(
      serialNumber: serialNumber,
      containerNumber: containerNumber,
      doNumber: doNumber,
    );
    if (result['success'] == true) {
      return {
        'message': 'Scan berhasil',
        'model': result['model'],
        'scannedToday': result['scannedToday'],
        'allowedQty': result['allowedQty'],
      };
    } else {
      throw http.Response(
        '{"error":"${result['error']}"}',
        (result['error']?.contains('sudah discan') == true || result['error']?.contains('sudah pernah discan') == true)
            ? 409
            : result['error']?.contains('Qty') == true
            ? 422
            : 400,
      );
    }
  }

  /// Hybrid penuh — soft delete lokal (isDeleted + syncStatus), lalu coba delete server
  Future<void> deleteScanItem(int id) async {
    final database = await LocalDatabase.db;
    await database.update(
      'ScannedItems',
      {
        'isDeleted': 1,
        'syncStatus': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    // Best effort — coba hapus dari server
    try {
      final response = await client.delete(
        Uri.parse('$apiBaseUrl/api/scan/$id'),
        headers: _headers,
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 204) {
        await database.update(
          'ScannedItems',
          {'syncStatus': 'synced'},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    } catch (_) {
      // Offline — akan di-sync nanti via syncPendingData
    }
  }

  /// Hybrid — update lokal dulu (pending), lalu coba sync ke server
  Future<void> updateScanItem(
      int id, String serialNumber, int quantity) async {
    final database = await LocalDatabase.db;
    await database.update(
      'ScannedItems',
      {
        'serialNumber': serialNumber,
        'quantity': quantity,
        'syncStatus': 'pending',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    // Best effort — coba update ke server
    try {
      final response = await client.put(
        Uri.parse('$apiBaseUrl/api/scan/$id'),
        headers: _headers,
        body: jsonEncode({
          'serialNumber': serialNumber,
          'quantity': quantity,
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        await database.update(
          'ScannedItems',
          {'syncStatus': 'synced'},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    } catch (_) {
      // Offline — akan di-sync nanti
    }
  }

  // ─────────────────────────────────────────────
  // EXPORT
  // ─────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getExportData(
      String dateStr, {
        required String bookingConfirmation,
      }) async {
    final uri = Uri.parse(
        '$apiBaseUrl/api/export?date=$dateStr&bookingConfirmation=${Uri.encodeComponent(bookingConfirmation)}');
    final response = await client.get(uri, headers: _headers);
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      final list = body is Map ? body['data'] as List : body as List;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } else {
      throw Exception('Gagal mengambil data export: ${response.body}');
    }
  }

  Future<void> uploadExportFile(
      List<int> fileBytes, String fileName) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$apiBaseUrl/api/upload'),
    )
      ..headers['x-api-key'] = apiKey
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: fileName,
      ));
    final response = await request.send();
    if (response.statusCode != 200) {
      throw Exception('Gagal upload file ke backend');
    }
  }

  // ─────────────────────────────────────────────
  // SYNC
  // ─────────────────────────────────────────────

  /// Sync semua data lokal yang masih pending ke server.
  ///
  /// PENTING: Blok ini hanya sync Entries dan EntryDetails.
  /// ScannedItems TIDAK di-sync di sini karena jalur ini tidak membawa doText,
  /// yang menyebabkan backend selalu fallback ke DO pertama saat ada
  /// beberapa DO dengan model/prefix yang sama.
  ///
  /// ScannedItems di-sync HANYA oleh ApiService.syncPendingScans()
  /// (dipanggil dari SyncService._trySyncNow()) yang sudah membawa doText.
  Future<void> syncPendingData() async {
    final database = await LocalDatabase.db;

    // CATATAN PENTING:
    // Jangan sync ScannedItems di sini.
    // ScannedItems hanya boleh disync oleh ApiService.syncPendingScans(),
    // karena fungsi itu mengirim doText + serverDetailId.

    // 1. Sync delete scan yang pending.
    // Untuk item yang sudah punya serverItemId, delete harus ke id server.
    // Jika belum punya serverItemId, cukup biarkan lokal sampai sync scan berhasil.
    final pendingDeletes = await database.query(
      'ScannedItems',
      where: 'syncStatus = ? AND isDeleted = ?',
      whereArgs: ['pending', 1],
    );

    for (final row in pendingDeletes) {
      try {
        final localId = row['id'] as int;
        final serverItemId = row['serverItemId'] as int?;

        if (serverItemId == null || serverItemId <= 0) {
          print('[SYNC] Skip delete scan local=$localId karena belum punya serverItemId');
          continue;
        }

        final response = await client.delete(
          Uri.parse('$apiBaseUrl/api/scan/$serverItemId'),
          headers: _headers,
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200 || response.statusCode == 204 || response.statusCode == 404) {
          await database.delete(
            'ScannedItems',
            where: 'id = ?',
            whereArgs: [localId],
          );
        } else {
          print('[SYNC] Delete scan local=$localId server=$serverItemId gagal: ${response.statusCode}');
          print('[SYNC] BODY: ${response.body}');
        }
      } catch (e) {
        print('[SYNC] Delete scan error: $e');
      }
    }

    // 2. Jangan PUT EntryDetails pending yang entry-nya belum punya serverId.
    // Bug lama: local detail id dipakai sebagai SQL DetailId, padahal keduanya beda.
    // Detail offline baru disimpan lewat POST /api/entries di bawah, lalu server
    // mengembalikan mapping clientDetailId -> detailId.
    final pendingEntries = await database.query(
      'Entries',
      where: 'serverId IS NULL',
      orderBy: 'id ASC',
    );

    for (final entry in pendingEntries) {
      final localId = entry['id'] as int;

      try {
        final details = await database.query(
          'EntryDetails',
          where: 'entryId = ?',
          whereArgs: [localId],
          orderBy: 'id ASC',
        );

        if (details.isEmpty) {
          print('[SYNC] Entry local=$localId dilewati — tidak ada detail');
          continue;
        }

        final payload = {
          'date': entry['entryDate'],
          'containerNumber': entry['containerNumber'],
          'bookingConfirmation': entry['bookingConfirmation'],
          'items': details.map((d) => {
            // clientDetailId adalah id SQLite lokal.
            // Backend fix terbaru akan mengembalikan mapping ini ke DetailId SQL.
            'clientDetailId': d['id'],
            'model':          d['model'],
            'contNo':         d['contNo'],
            'destination':    d['destination'],
            'drlNumber':      d['drlNumber'],
            'doText':         d['doText'],
            'serialNumber':   d['serialNumber'],
            'quantity':       d['quantity'],
          }).toList(),
        };

        print('[SYNC] → POST /api/entries localEntry=$localId details=${details.length}');

        final response = await client.post(
          Uri.parse('$apiBaseUrl/api/entries'),
          headers: _headers,
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode != 200 && response.statusCode != 201) {
          print('[SYNC] Entry $localId failed');
          print('[SYNC] STATUS : ${response.statusCode}');
          print('[SYNC] BODY   : ${response.body}');
          continue;
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final serverId = body['entryId'] as int?;

        if (serverId == null) {
          print('[SYNC] Entry $localId gagal: response tidak punya entryId');
          print('[SYNC] BODY: ${response.body}');
          continue;
        }

        await LocalDatabase.markEntrySynced(localId, serverId);

        // Mapping utama dari backend fix terbaru: body.details
        final mappedLocalIds = <int>{};

        if (body['details'] is List) {
          final serverDetails = body['details'] as List;
          for (final item in serverDetails) {
            if (item is! Map) continue;

            final clientDetailId = item['clientDetailId'];
            final detailId = item['detailId'];

            if (clientDetailId is int && detailId is int && detailId > 0) {
              await LocalDatabase.markDetailSynced(clientDetailId, detailId);
              mappedLocalIds.add(clientDetailId);
              print('[SYNC] ✓ Detail local=$clientDetailId → serverDetailId=$detailId');
            }
          }
        }

        // Fallback untuk backend lama yang belum return body.details:
        // ambil detail berdasarkan entryId SQL lalu cocokkan ke local detail.
        if (mappedLocalIds.length < details.length) {
          try {
            final getDetailsRes = await client.get(
              Uri.parse('$apiBaseUrl/api/entries/$serverId/details'),
              headers: _headers,
            ).timeout(const Duration(seconds: 10));

            if (getDetailsRes.statusCode == 200) {
              final serverDetails = jsonDecode(getDetailsRes.body) as List;
              final usedServerDetailIds = <int>{};

              for (var i = 0; i < details.length; i++) {
                final localDetail = details[i];
                final localDetailId = localDetail['id'] as int;
                if (mappedLocalIds.contains(localDetailId)) continue;

                Map<String, dynamic>? chosen;

                // Cocokkan berdasarkan DO + prefix + model dulu
                for (final sdRaw in serverDetails) {
                  if (sdRaw is! Map) continue;
                  final sd = Map<String, dynamic>.from(sdRaw);
                  final sid = sd['detailId'];
                  if (sid is int && usedServerDetailIds.contains(sid)) continue;

                  final sameDo = (sd['doText']?.toString() ?? '') == (localDetail['doText']?.toString() ?? '');
                  final sameSerial = (sd['serialNumber']?.toString() ?? '') == (localDetail['serialNumber']?.toString() ?? '');
                  final sameModel = (sd['model']?.toString() ?? '') == (localDetail['model']?.toString() ?? '');

                  if (sameDo && sameSerial && sameModel) {
                    chosen = sd;
                    break;
                  }
                }

                // Kalau tidak ketemu, fallback by order
                chosen ??= (i < serverDetails.length && serverDetails[i] is Map)
                    ? Map<String, dynamic>.from(serverDetails[i] as Map)
                    : null;

                final serverDetailId = chosen?['detailId'];
                if (serverDetailId is int && serverDetailId > 0) {
                  await LocalDatabase.markDetailSynced(localDetailId, serverDetailId);
                  mappedLocalIds.add(localDetailId);
                  usedServerDetailIds.add(serverDetailId);
                  print('[SYNC] ✓ Detail fallback local=$localDetailId → serverDetailId=$serverDetailId');
                }
              }
            } else {
              print('[SYNC] Gagal GET detail server entry=$serverId: ${getDetailsRes.statusCode}');
              print('[SYNC] BODY: ${getDetailsRes.body}');
            }
          } catch (e) {
            print('[SYNC] Fallback detail mapping error: $e');
          }
        }

        if (mappedLocalIds.length < details.length) {
          print('[SYNC] ⚠ Entry $localId synced, tapi detail mapping belum lengkap '
              '(${mappedLocalIds.length}/${details.length}). Scan mungkin belum bisa sync.');
        } else {
          print('[SYNC] ✓ Entry $localId synced dengan semua serverDetailId');
        }
      } catch (e) {
        print('[SYNC] Entry $localId exception: $e');
      }
    }

    // 3. Update detail yang memang sudah punya serverDetailId.
    // Ini untuk edit detail setelah entry pernah sync.
    final pendingDetails = await database.query(
      'EntryDetails',
      where: 'syncStatus = ? AND serverDetailId IS NOT NULL',
      whereArgs: ['pending'],
    );

    for (final row in pendingDetails) {
      try {
        final localDetailId = row['id'] as int;
        final serverDetailId = row['serverDetailId'] as int?;

        if (serverDetailId == null || serverDetailId <= 0) continue;

        final payload = Map<String, dynamic>.from(row)
          ..remove('id')
          ..remove('entryId')
          ..remove('syncStatus')
          ..remove('serverDetailId');

        final response = await client.put(
          Uri.parse('$apiBaseUrl/api/details/$serverDetailId'),
          headers: _headers,
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          await LocalDatabase.markDetailSynced(localDetailId, serverDetailId);
          print('[SYNC] ✓ Updated detail local=$localDetailId server=$serverDetailId');
        } else {
          print('[SYNC] Update detail local=$localDetailId server=$serverDetailId gagal: ${response.statusCode}');
          print('[SYNC] BODY: ${response.body}');
        }
      } catch (e) {
        print('[SYNC] Update detail error: $e');
      }
    }
  }
}
