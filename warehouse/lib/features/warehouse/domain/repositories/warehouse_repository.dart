import '../entities/scanned_item.dart';
import '../entities/entry_detail.dart';

abstract class WarehouseRepository {
  Future<List<Map<String, String>>> getModels();

  Future<List<String>> getTodaySubmittedModels(DateTime date);

  Future<void> submitEntry({
    required DateTime date,
    required String containerNumber,
    required String? bookingConfirmation,
    required List<Map<String, dynamic>> items,
  });

  Future<List<EntryDetail>> fetchEntriesForDate(DateTime date);

  Future<void> updateEntryDetail(int detailId, Map<String, dynamic> payload);

  Future<List<Map<String, dynamic>>> getContainersToday();
  Future<List<Map<String, dynamic>>> getBookingsToday();

  Future<List<Map<String, dynamic>>> getContainerDetails(String containerNumber);

  Future<List<ScannedItem>> getScannedToday();

  Future<List<ScannedItem>> getScannedByContainer(String containerNumber);

  Future<Map<String, dynamic>> scanSerialNumber(
      String serialNumber,
      String containerNumber, {
        String? doNumber,
      });

  Future<void> deleteScanItem(int id);

  Future<void> updateScanItem(int id,
      {required String serialNumber, required int quantity});

  Future<List<Map<String, dynamic>>> getExportData(
    DateTime date, {
    required String bookingConfirmation,
  });

  Future<void> uploadExportFile(List<int> fileBytes, String fileName);
}
