import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class LocalDatabase {
  static Database? _db;
  static const int _version = 2;

  static Future<Database> get db async {
    try {
      _db ??= await _initDb();
      return _db!;
    } catch (e) {
      print('[DB ERROR] $e');
      rethrow;
    }
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'warehouse.db');

    return await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        // Jangan drop data lokal saat upgrade. Data offline scan bisa penting.
        await _migrate(db);
      },
      onOpen: (db) async {
        // Safety net untuk device yang sudah punya DB lama tetapi versinya sama.
        await _migrate(db);
      },
    );
  }

  static Future<void> _migrate(Database db) async {
    Future<void> ensureColumn(String table, String column, String definition) async {
      final cols = await db.rawQuery('PRAGMA table_info($table)');
      if (cols.isEmpty) return; // table belum ada / fresh install ditangani oleh _onCreate
      final exists = cols.any((c) => c['name'] == column);
      if (!exists) {
        await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
      }
    }

    await ensureColumn('Entries', 'containerNumber', 'TEXT');
    await ensureColumn('Entries', 'bookingConfirmation', 'TEXT');
    await ensureColumn('Entries', 'syncStatus', "TEXT DEFAULT 'pending'");
    await ensureColumn('Entries', 'serverId', 'INTEGER');

    await ensureColumn('EntryDetails', 'syncStatus', "TEXT DEFAULT 'pending'");
    await ensureColumn('EntryDetails', 'serverDetailId', 'INTEGER');

    await ensureColumn('ScannedItems', 'contNo', 'TEXT');
    await ensureColumn('ScannedItems', 'destination', 'TEXT');
    await ensureColumn('ScannedItems', 'drlNumber', 'TEXT');
    await ensureColumn('ScannedItems', 'doText', 'TEXT');
    await ensureColumn('ScannedItems', 'containerNumber', 'TEXT');
    await ensureColumn('ScannedItems', 'syncStatus', "TEXT DEFAULT 'pending'");
    await ensureColumn('ScannedItems', 'isDeleted', 'INTEGER DEFAULT 0');
    await ensureColumn('ScannedItems', 'serverItemId', 'INTEGER');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE Entries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        entryDate       TEXT NOT NULL,
        containerNumber TEXT,
        bookingConfirmation TEXT,
        syncStatus      TEXT DEFAULT 'pending',
        serverId        INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE EntryDetails (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        entryId        INTEGER NOT NULL,
        model          TEXT,
        contNo         TEXT,
        destination    TEXT,
        drlNumber      TEXT,
        doText         TEXT,
        serialNumber   TEXT,
        quantity       INTEGER,
        syncStatus     TEXT DEFAULT 'pending',
        serverDetailId INTEGER,
        FOREIGN KEY (entryId) REFERENCES Entries(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE ScannedItems (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        entryDetailId   INTEGER NOT NULL,
        model           TEXT,
        serialNumber    TEXT NOT NULL,
        quantity        INTEGER DEFAULT 1,
        scannedAt       TEXT DEFAULT (datetime('now','localtime')),
        contNo          TEXT,
        destination     TEXT,
        drlNumber       TEXT,
        doText          TEXT,
        containerNumber TEXT,
        syncStatus      TEXT DEFAULT 'pending',
        isDeleted       INTEGER DEFAULT 0,
        serverItemId    INTEGER,
        FOREIGN KEY (entryDetailId) REFERENCES EntryDetails(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE MasterData (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        productId      TEXT,
        marking        TEXT,
        productName    TEXT,
        machineCode    TEXT,
        description    TEXT,
        prodPlan       INTEGER,
        sut            REAL,
        noOfOperator   INTEGER,
        qtyHour        INTEGER,
        prodHeadHour   INTEGER,
        cycleTimeVacum INTEGER,
        workHour       INTEGER
      )
    ''');
  }

  // ═══════════════════════════════════════════════════
  // ENTRIES
  // ═══════════════════════════════════════════════════

  /// Dari server → langsung synced
  static Future<int> insertEntryFromServer({
    required String entryDate,
    required String? containerNumber,
    required String? bookingConfirmation,
    required int serverId,
  }) async {
    final database = await db;
    final existing = await database.query(
      'Entries',
      where: 'serverId = ?',
      whereArgs: [serverId],
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;

    return await database.insert('Entries', {
      'entryDate': entryDate,
      'containerNumber': containerNumber,
      'bookingConfirmation': bookingConfirmation,
      'syncStatus': 'synced',
      'serverId': serverId,
    });
  }

  /// Buat entry baru secara lokal (offline) → pending sync
  static Future<int> insertEntryLocal({
    required String entryDate,
    required String? containerNumber,
    required String? bookingConfirmation,
  }) async {
    final database = await db;
    return await database.insert('Entries', {
      'entryDate': entryDate,
      'containerNumber': containerNumber,
      'bookingConfirmation': bookingConfirmation,
      'syncStatus': 'pending',
      'serverId': null,
    });
  }

  /// Terima DateTime + containerNumber + items, lalu insert entry + semua details sekaligus
  static Future<void> saveEntry({
    required DateTime date,
    required String? containerNumber,
    required String? bookingConfirmation,
    required List<Map<String, dynamic>> items,
  }) async {
    final entryDate = date.toIso8601String().substring(0, 10);
    final localEntryId = await insertEntryLocal(
      entryDate: entryDate,
      containerNumber: containerNumber,
      bookingConfirmation: bookingConfirmation,
    );
    for (final item in items) {
      await insertDetailLocal(
        localEntryId: localEntryId,
        model: item['model'],
        contNo: item['contNo'],
        destination: item['destination'],
        drlNumber: item['drlNumber'],
        doText: item['doText'],
        serialNumber: item['serialNumber'],
        quantity: (item['quantity'] as int?) ?? 1,
      );
    }
  }

  static Future<List<Map<String, dynamic>>> getEntries() async {
    final database = await db;
    return await database.query('Entries', orderBy: 'id DESC');
  }

  /// Ambil semua entry yang belum di-sync ke server
  static Future<List<Map<String, dynamic>>> getPendingEntries() async {
    final database = await db;
    return await database.query(
      'Entries',
      where: 'syncStatus = ?',
      whereArgs: ['pending'],
      orderBy: 'id ASC',
    );
  }

  /// Update entry setelah berhasil di-sync — simpan serverId yang balik dari server
  static Future<void> markEntrySynced(int localId, int serverId) async {
    final database = await db;
    await database.update(
      'Entries',
      {'syncStatus': 'synced', 'serverId': serverId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  // ═══════════════════════════════════════════════════
  // ENTRY DETAILS
  // ═══════════════════════════════════════════════════

  /// Dari server → langsung synced
  static Future<int> insertDetailFromServer({
    required int localEntryId,
    required int serverDetailId,
    required String? model,
    required String? contNo,
    required String? destination,
    required String? drlNumber,
    required String? doText,
    required String? serialNumber,
    required int quantity,
  }) async {
    final database = await db;
    final existing = await database.query(
      'EntryDetails',
      where: 'serverDetailId = ?',
      whereArgs: [serverDetailId],
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;

    return await database.insert('EntryDetails', {
      'entryId': localEntryId,
      'model': model,
      'contNo': contNo,
      'destination': destination,
      'drlNumber': drlNumber,
      'doText': doText,
      'serialNumber': serialNumber,
      'quantity': quantity,
      'syncStatus': 'synced',
      'serverDetailId': serverDetailId,
    });
  }

  /// Buat detail baru secara lokal (offline) → pending sync
  static Future<int> insertDetailLocal({
    required int localEntryId,
    required String? model,
    required String? contNo,
    required String? destination,
    required String? drlNumber,
    required String? doText,
    required String? serialNumber,
    required int quantity,
  }) async {
    final database = await db;
    return await database.insert('EntryDetails', {
      'entryId': localEntryId,
      'model': model,
      'contNo': contNo,
      'destination': destination,
      'drlNumber': drlNumber,
      'doText': doText,
      'serialNumber': serialNumber,
      'quantity': quantity,
      'syncStatus': 'pending',
      'serverDetailId': null,
    });
  }

  /// Ambil semua EntryDetails berdasarkan tanggal (dari Entries.entryDate)
  static Future<List<Map<String, dynamic>>> getAllDetailsByDate(
      String dateStr) async {
    final database = await db;
    return await database.rawQuery('''
      SELECT d.*, e.containerNumber, e.entryDate, e.serverId
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE date(e.entryDate) = date(?)
      ORDER BY e.containerNumber, d.model
    ''', [dateStr]);
  }

  /// Update satu row EntryDetails berdasarkan id
  static Future<void> updateDetail(
      int detailId, Map<String, dynamic> payload) async {
    final database = await db;
    await database.update(
      'EntryDetails',
      {...payload, 'syncStatus': 'pending'},
      where: 'id = ?',
      whereArgs: [detailId],
    );
  }

  static Future<List<Map<String, dynamic>>> getDetailsByEntryId(
      int localEntryId) async {
    final database = await db;
    return await database.query(
      'EntryDetails',
      where: 'entryId = ?',
      whereArgs: [localEntryId],
    );
  }

  static Future<List<Map<String, dynamic>>> getDetailsByContainerNumber(
      String containerNumber) async {
    final database = await db;
    return await database.rawQuery('''
      SELECT d.*, e.containerNumber,
        (SELECT COUNT(*) FROM ScannedItems s
         WHERE s.entryDetailId = d.id
           AND (s.doText = d.doText OR (s.doText IS NULL AND d.doText IS NULL))
           AND date(s.scannedAt) = date('now','localtime')
           AND (s.isDeleted IS NULL OR s.isDeleted = 0)
        ) as scannedToday
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE e.containerNumber = ?
        AND date(e.entryDate) = date('now','localtime')
      ORDER BY d.doText ASC, d.model ASC
    ''', [containerNumber]);
  }

  /// Ambil semua details yang belum di-sync (butuh localEntryId untuk filter per entry)
  static Future<List<Map<String, dynamic>>> getPendingDetailsByEntryId(
      int localEntryId) async {
    final database = await db;
    return await database.query(
      'EntryDetails',
      where: 'entryId = ? AND syncStatus = ?',
      whereArgs: [localEntryId, 'pending'],
      orderBy: 'id ASC',
    );
  }

  /// Update detail setelah berhasil di-sync — simpan serverDetailId
  static Future<void> markDetailSynced(
      int localId, int serverDetailId) async {
    final database = await db;
    await database.update(
      'EntryDetails',
      {'syncStatus': 'synced', 'serverDetailId': serverDetailId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  // ═══════════════════════════════════════════════════
  // SERIAL MATCHING
  // ═══════════════════════════════════════════════════

  /// FIX: tambah parameter doText supaya match hanya ke detail DO yang aktif
  /// Mencegah model yang sama di DO berbeda saling bertabrakan
  static Future<Map<String, dynamic>?> matchSerialPrefix(
      String input,
      String containerNumber, {
        String? doText,
      }) async {
    final database = await db;
    final results = await database.rawQuery('''
      SELECT d.id as detailId, d.model, d.serialNumber, d.quantity,
             d.contNo, d.destination, d.drlNumber, d.doText,
             e.containerNumber
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE ? LIKE d.serialNumber || '%'
        AND d.serialNumber IS NOT NULL
        AND d.serialNumber != ''
        AND date(e.entryDate) = date('now','localtime')
        AND e.containerNumber = ?
        ${doText != null ? "AND d.doText = ?" : ""}
      ORDER BY 
        CASE WHEN d.quantity > (
            SELECT COUNT(*) FROM ScannedItems sx 
            WHERE sx.entryDetailId = d.id 
              AND date(sx.scannedAt) = date('now','localtime')
              AND (sx.isDeleted IS NULL OR sx.isDeleted = 0)
        ) THEN 0 ELSE 1 END ASC,
        LENGTH(d.serialNumber) DESC
      LIMIT 1
    ''', doText != null ? [input, containerNumber, doText] : [input, containerNumber]);

    return results.isEmpty ? null : results.first;
  }

  static Future<String?> findContainerForSerial(String input) async {
    final database = await db;
    final results = await database.rawQuery('''
      SELECT e.containerNumber
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE ? LIKE d.serialNumber || '%'
        AND d.serialNumber IS NOT NULL
        AND d.serialNumber != ''
        AND date(e.entryDate) = date('now','localtime')
      ORDER BY LENGTH(d.serialNumber) DESC
      LIMIT 1
    ''', [input]);

    if (results.isEmpty) return null;
    return results.first['containerNumber'] as String?;
  }

  // ═══════════════════════════════════════════════════
  // SCANNED ITEMS
  // ═══════════════════════════════════════════════════

  /// Cek duplicate berdasarkan entryDetailId yang sudah di-match.
  /// Ini lebih presisi daripada hanya DoText, karena entryDetailId sudah mewakili
  /// kombinasi container + DO + model + prefix.
  ///
  /// Fallback doText tetap disediakan supaya tidak mematahkan pemanggilan lama,
  static Future<String?> checkDuplicateInContainer(
    String serialNumber,
    String containerNumber,
  ) async {
    final database = await db;
    final result = await database.rawQuery('''
      SELECT d.doText
      FROM ScannedItems s
      JOIN EntryDetails d ON s.entryDetailId = d.id
      JOIN Entries e ON d.entryId = e.id
      WHERE s.serialNumber = ?
        AND e.containerNumber = ?
        AND date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
      LIMIT 1
    ''', [serialNumber, containerNumber]);

    if (result.isNotEmpty) {
      return result.first['doText'] as String?;
    }
    return null;
  }

  /// Cek duplicate berdasarkan entryDetailId yang sudah di-match.
  /// Ini lebih presisi daripada hanya DoText, karena entryDetailId sudah mewakili
  /// kombinasi container + DO + model + prefix.
  ///
  /// Fallback doText tetap disediakan supaya tidak mematahkan pemanggilan lama,
  /// tetapi flow scan utama wajib mengirim entryDetailId.
  static Future<bool> isDuplicateScan(
    String serialNumber, {
    int? entryDetailId,
    String? doText,
  }) async {
    final database = await db;

    final whereExtra = entryDetailId != null
        ? 'AND s.entryDetailId = ?'
        : (doText != null ? 'AND d.doText = ?' : '');

    final args = <dynamic>[serialNumber];
    if (entryDetailId != null) {
      args.add(entryDetailId);
    } else if (doText != null) {
      args.add(doText);
    }

    final result = await database.rawQuery('''
      SELECT COUNT(*) as cnt
      FROM ScannedItems s
      JOIN EntryDetails d ON s.entryDetailId = d.id
      WHERE s.serialNumber = ?
        AND date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
        $whereExtra
    ''', args);

    return (result.first['cnt'] as int) > 0;
  }

  /// Hitung qty berdasarkan detail yang aktif.
  /// Jangan filter ulang memakai DoText, karena detailId sudah cukup spesifik.
  static Future<int> countScannedToday(int detailId, {String? doText}) async {
    final database = await db;
    final result = await database.rawQuery('''
      SELECT COUNT(*) as cnt
      FROM ScannedItems s
      WHERE s.entryDetailId = ?
        AND date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
    ''', [detailId]);
    return result.first['cnt'] as int;
  }

  static Future<int> insertScan({
    required int entryDetailId,
    required String model,
    required String serialNumber,
    required String? contNo,
    required String? destination,
    required String? drlNumber,
    required String? doText,
    required String? containerNumber,
  }) async {
    final database = await db;
    return await database.insert('ScannedItems', {
      'entryDetailId': entryDetailId,
      'model': model,
      'serialNumber': serialNumber,
      'contNo': contNo,
      'destination': destination,
      'drlNumber': drlNumber,
      'doText': doText,
      'containerNumber': containerNumber,
      'syncStatus': 'pending',
      'isDeleted': 0,
    });
  }

  static Future<List<Map<String, dynamic>>> getScannedToday() async {
    final database = await db;
    return await database.rawQuery('''
      SELECT s.*, 
        (SELECT COUNT(*) FROM ScannedItems sx 
         WHERE sx.entryDetailId = s.entryDetailId
           AND date(sx.scannedAt) = date('now','localtime')
           AND (sx.isDeleted IS NULL OR sx.isDeleted = 0)
        ) as scannedCount,
        d.quantity as allowedQty
      FROM ScannedItems s
      JOIN EntryDetails d ON s.entryDetailId = d.id
      WHERE date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
      ORDER BY s.scannedAt DESC
    ''');
  }

  /// Ambil model yang sudah di-submit pada tanggal tertentu dari SQLite lokal
  static Future<List<String>> getTodaySubmittedModels(DateTime date) async {
    final dateStr = date.toIso8601String().substring(0, 10);
    final database = await db;
    final results = await database.rawQuery('''
      SELECT DISTINCT d.model
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE date(e.entryDate) = date(?)
        AND d.model IS NOT NULL
        AND d.model != ''
    ''', [dateStr]);

    return results
        .map((r) => r['model']?.toString() ?? '')
        .where((m) => m.isNotEmpty)
        .toList();
  }

  /// Ambil scan yang masih PENDING saja (belum pernah dicoba atau gagal transient).
  /// PENTING: Jangan masukkan 'failed' di sini!
  /// Scan yang sudah ditandai 'failed' (mis. 422 "Quantity sudah terpenuhi")
  /// adalah permanent error — retry tidak akan berhasil dan hanya akan
  /// menyebabkan infinite loop. User harus menghapus scan failed secara manual.
  static Future<List<Map<String, dynamic>>> getPendingScans() async {
    final database = await db;
    return await database.query(
      'ScannedItems',
      where: 'syncStatus = ? AND (isDeleted IS NULL OR isDeleted = 0)',
      whereArgs: ['pending'],
      orderBy: 'scannedAt ASC',
    );
  }

  /// Hitung jumlah scan yang gagal sync (permanent error dari server).
  /// Digunakan untuk menampilkan notifikasi ke user.
  static Future<int> getFailedScansCount() async {
    final database = await db;
    final result = await database.rawQuery('''
      SELECT COUNT(*) as cnt FROM ScannedItems
      WHERE syncStatus = 'failed'
        AND (isDeleted IS NULL OR isDeleted = 0)
    ''');
    return result.first['cnt'] as int;
  }

  /// Ambil detail scan yang gagal untuk ditampilkan ke user.
  static Future<List<Map<String, dynamic>>> getFailedScans() async {
    final database = await db;
    return await database.query(
      'ScannedItems',
      where: 'syncStatus = ? AND (isDeleted IS NULL OR isDeleted = 0)',
      whereArgs: ['failed'],
      orderBy: 'scannedAt ASC',
    );
  }

  static Future<void> markScanSynced(int localId, int? serverId) async {
    final database = await db;
    await database.update(
      'ScannedItems',
      {'syncStatus': 'synced', 'serverItemId': serverId},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  static Future<void> markScanFailed(int localId) async {
    final database = await db;
    await database.update(
      'ScannedItems',
      {'syncStatus': 'failed'},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  static Future<void> clearFailedScans() async {
    final database = await db;
    await database.delete(
      'ScannedItems',
      where: 'syncStatus = ?',
      whereArgs: ['failed'],
    );
  }

  // ═══════════════════════════════════════════════════
  // DELETE DATA SETELAH SYNC BERHASIL (CLEANUP)
  // ═══════════════════════════════════════════════════

  /// Hapus satu ScannedItem berdasarkan id (setelah sync sukses)
  static Future<void> deleteScan(int localId) async {
    try {
      final database = await db;
      await database.delete(
        'ScannedItems',
        where: 'id = ?',
        whereArgs: [localId],
      );
      print('[DB] Scan $localId deleted');
    } catch (e) {
      print('[DB ERROR] Failed to delete scan $localId: $e');
    }
  }

  /// Hapus EntryDetails berdasarkan id (setelah sync sukses)
  static Future<void> deleteDetailById(int detailId) async {
    try {
      final database = await db;
      await database.delete(
        'EntryDetails',
        where: 'id = ?',
        whereArgs: [detailId],
      );
      print('[DB] Detail $detailId deleted');
    } catch (e) {
      print('[DB ERROR] Failed to delete detail $detailId: $e');
    }
  }

  /// Hapus Entry beserta semua Details & ScannedItems-nya (cascade delete)
  /// URUTAN PENTING: ScannedItems → EntryDetails → Entries
  static Future<void> deleteEntryById(int entryId) async {
    try {
      final database = await db;

      // 1. Hapus ScannedItems yang reference EntryDetails-nya
      await database.rawDelete('''
        DELETE FROM ScannedItems
        WHERE entryDetailId IN (
          SELECT id FROM EntryDetails WHERE entryId = ?
        )
      ''', [entryId]);

      // 2. Hapus EntryDetails
      await database.delete(
        'EntryDetails',
        where: 'entryId = ?',
        whereArgs: [entryId],
      );

      // 3. Hapus Entry
      await database.delete(
        'Entries',
        where: 'id = ?',
        whereArgs: [entryId],
      );

      print('[DB] Entry $entryId & related data deleted');
    } catch (e) {
      print('[DB ERROR] Failed to delete entry $entryId: $e');
    }
  }

  /// Cleanup maintenance: hapus semua entries yang sudah synced
  static Future<int> deleteSyncedEntries() async {
    try {
      final database = await db;
      final count = await database.delete(
        'Entries',
        where: 'syncStatus = ?',
        whereArgs: ['synced'],
      );
      print('[DB] Deleted $count synced entries');
      return count;
    } catch (e) {
      print('[DB ERROR] Failed to delete synced entries: $e');
      return 0;
    }
  }

  /// Cleanup maintenance: hapus semua scans yang sudah synced
  static Future<int> deleteSyncedScans() async {
    try {
      final database = await db;
      final count = await database.delete(
        'ScannedItems',
        where: 'syncStatus = ?',
        whereArgs: ['synced'],
      );
      print('[DB] Deleted $count synced scans');
      return count;
    } catch (e) {
      print('[DB ERROR] Failed to delete synced scans: $e');
      return 0;
    }
  }

  // ═══════════════════════════════════════════════════
  // MASTER DATA
  // ═══════════════════════════════════════════════════

  static Future<bool> isMasterDataEmpty() async {
    final database = await db;
    final result = await database.query('MasterData', limit: 1);
    return result.isEmpty;
  }

  static Future<void> insertMasterData(
      List<Map<String, dynamic>> items) async {
    final database = await db;
    final batch = database.batch();
    for (final item in items) {
      batch.insert(
        'MasterData',
        {
          'productId': item['productId'],
          'marking': item['marking'],
          'productName': item['productName'],
          'machineCode': item['machineCode'],
          'description': item['description'],
          'prodPlan': item['prodPlan'],
          'sut': item['sut'],
          'noOfOperator': item['noOfOperator'],
          'qtyHour': item['qtyHour'],
          'prodHeadHour': item['prodHeadHour'],
          'cycleTimeVacum': item['cycleTimeVacum'],
          'workHour': item['workHour'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
    print('[DB] MasterData inserted: ${items.length} items');
  }

  static Future<List<Map<String, dynamic>>> getMasterData() async {
    final database = await db;
    return await database.query('MasterData', orderBy: 'productName ASC');
  }

  // ═══════════════════════════════════════════════════
  // CUSTOM TABLE
  // ═══════════════════════════════════════════════════

  static Future<void> createCustomTable(
      String tableName, String columnsDDL) async {
    final database = await db;
    await database.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        $columnsDDL
      )
    ''');
  }

  static Future<int> insertToTable(
      String tableName, Map<String, dynamic> data) async {
    final database = await db;
    return await database.insert(tableName, data);
  }

  static Future<List<Map<String, dynamic>>> queryTable(
      String tableName, {
        String? where,
        List<dynamic>? whereArgs,
        String? orderBy,
      }) async {
    final database = await db;
    return await database.query(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
    );
  }
}
