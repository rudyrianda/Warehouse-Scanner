import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  sqfliteFfiInit();
  var databaseFactory = databaseFactoryFfi;
  var db = await databaseFactory.openDatabase(inMemoryDatabasePath);

  await db.execute('''
      CREATE TABLE Entries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        entryDate       TEXT NOT NULL,
        containerNumber TEXT
      )
    ''');

  await db.execute('''
      CREATE TABLE EntryDetails (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        entryId        INTEGER NOT NULL,
        doText         TEXT,
        serialNumber   TEXT,
        quantity       INTEGER
      )
    ''');

  await db.execute('''
      CREATE TABLE ScannedItems (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        entryDetailId   INTEGER NOT NULL,
        serialNumber    TEXT NOT NULL,
        scannedAt       TEXT DEFAULT (datetime('now','localtime')),
        isDeleted       INTEGER DEFAULT 0
      )
    ''');

  // Insert 3 DOs in the same container with the same prefix '123'
  await db.insert('Entries', {'id': 1, 'entryDate': DateTime.now().toIso8601String().substring(0, 10), 'containerNumber': 'C1'});
  
  await db.insert('EntryDetails', {'id': 1, 'entryId': 1, 'doText': 'D1', 'serialNumber': '123', 'quantity': 30});
  await db.insert('EntryDetails', {'id': 2, 'entryId': 1, 'doText': 'D2', 'serialNumber': '123', 'quantity': 30});
  await db.insert('EntryDetails', {'id': 3, 'entryId': 1, 'doText': 'D3', 'serialNumber': '123', 'quantity': 30});

  print("---- SCENARIO: Scan %123%123 in D2 ----");
  // Cleaned input: '123%123'
  String input = '123%123';

  // Find DO 2
  var matchedD2 = await db.rawQuery('''
      SELECT d.id as detailId, d.doText, d.serialNumber, e.containerNumber
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE ? LIKE d.serialNumber || '%'
        AND d.serialNumber IS NOT NULL
        AND d.serialNumber != ''
        AND date(e.entryDate) = date('now','localtime')
        AND e.containerNumber = ?
        AND d.doText = ?
      LIMIT 1
  ''', [input, 'C1', 'D2']);

  print("Matched D2: " + matchedD2.toString());

  if (matchedD2.isNotEmpty) {
    // Insert into D2
    await db.insert('ScannedItems', {
      'entryDetailId': matchedD2.first['detailId'],
      'serialNumber': input
    });
    print("Successfully inserted '\$input' into D2.");
  }


  print("\\n---- SCENARIO: Scan %123%123 in D3 (THE ERROR CASE) ----");
  // User tries scanning in D3.
  var matchedD3 = await db.rawQuery('''
      SELECT d.id as detailId, d.doText, d.serialNumber, e.containerNumber
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE ? LIKE d.serialNumber || '%'
        AND d.serialNumber IS NOT NULL
        AND d.serialNumber != ''
        AND date(e.entryDate) = date('now','localtime')
        AND e.containerNumber = ?
        AND d.doText = ?
      LIMIT 1
  ''', [input, 'C1', 'D3']);

  print("Matched D3: " + matchedD3.toString());

  if (matchedD3.isEmpty) {
    // Fallback to findContainerForSerial
    var otherContainer = await db.rawQuery('''
      SELECT e.containerNumber, d.doText
      FROM EntryDetails d
      JOIN Entries e ON d.entryId = e.id
      WHERE ? LIKE d.serialNumber || '%'
        AND d.serialNumber IS NOT NULL
        AND d.serialNumber != ''
        AND date(e.entryDate) = date('now','localtime')
      ORDER BY LENGTH(d.serialNumber) DESC
      LIMIT 1
    ''', [input]);

    print("FindContainer fallback: " + otherContainer.toString());
    if (otherContainer.isNotEmpty) {
      print("ERROR: Serial number ini terdaftar untuk container " + otherContainer.first['containerNumber'].toString() + " (DO " + otherContainer.first['doText'].toString() + "), bukan untuk container C1 yang sedang dipilih.");
    }
  } else {
    print("Matched D3 successfully! Let's check duplicate.");
    
    // OLD duplicate check (per detail)
    var isDuplicateOld = await db.rawQuery('''
      SELECT COUNT(*) as cnt
      FROM ScannedItems s
      JOIN EntryDetails d ON s.entryDetailId = d.id
      WHERE s.serialNumber = ?
        AND date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
        AND s.entryDetailId = ?
    ''', [input, matchedD3.first['detailId']]);
    print("Old duplicate check: " + isDuplicateOld.first['cnt'].toString() + " (0 means success)");

    // NEW duplicate check (per container)
    var isDuplicateNew = await db.rawQuery('''
      SELECT d.doText
      FROM ScannedItems s
      JOIN EntryDetails d ON s.entryDetailId = d.id
      JOIN Entries e ON d.entryId = e.id
      WHERE s.serialNumber = ?
        AND e.containerNumber = ?
        AND date(s.scannedAt) = date('now','localtime')
        AND (s.isDeleted IS NULL OR s.isDeleted = 0)
      LIMIT 1
    ''', [input, 'C1']);
    print("New duplicate check: " + isDuplicateNew.toString());
  }

}
