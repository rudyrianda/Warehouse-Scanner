import '../../domain/repositories/warehouse_repository.dart';
import '../../domain/entities/scanned_item.dart';
import '../../domain/entities/entry_detail.dart';
import '../datasources/warehouse_remote_datasource.dart';

class WarehouseRepositoryImpl implements WarehouseRepository {
  final WarehouseRemoteDataSource remoteDataSource;

  WarehouseRepositoryImpl({required this.remoteDataSource});

  @override
  Future<List<Map<String, String>>> getModels() {
    return remoteDataSource.getModels();
  }

  @override
  Future<List<String>> getTodaySubmittedModels(DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return remoteDataSource.getTodaySubmittedModels(dateStr);
  }

  @override
  Future<void> submitEntry({
    required DateTime date,
    required String containerNumber,
    required String? bookingConfirmation,
    required List<Map<String, dynamic>> items,
  }) {
    return remoteDataSource.submitEntry(
      dateIso: date.toIso8601String(),
      containerNumber: containerNumber,
      bookingConfirmation: bookingConfirmation,
      items: items,
    );
  }

  @override
  Future<List<EntryDetail>> fetchEntriesForDate(DateTime date) async {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return remoteDataSource.fetchEntriesForDate(dateStr);
  }

  @override
  Future<void> updateEntryDetail(int detailId, Map<String, dynamic> payload) {
    return remoteDataSource.updateEntryDetail(detailId, payload);
  }

  @override
  Future<List<Map<String, dynamic>>> getContainersToday() {
    return remoteDataSource.getContainersToday();
  }

  @override
  Future<List<Map<String, dynamic>>> getBookingsToday() {
    return remoteDataSource.getBookingsToday();
  }

  @override
  Future<List<Map<String, dynamic>>> getContainerDetails(String containerNumber) {
    return remoteDataSource.getContainerDetails(containerNumber);
  }

  @override
  Future<List<ScannedItem>> getScannedToday() async {
    return remoteDataSource.getScannedToday();
  }

  @override
  Future<List<ScannedItem>> getScannedByContainer(String containerNumber) {
    return remoteDataSource.getScannedByContainer(containerNumber);
  }

  @override
  @override
  Future<Map<String, dynamic>> scanSerialNumber(
      String serialNumber,
      String containerNumber, {
        String? doNumber,
      }) {
    return remoteDataSource.scanSerialNumber(
      serialNumber,
      containerNumber,
      doNumber: doNumber,
    );
  }

  @override
  Future<void> deleteScanItem(int id) {
    return remoteDataSource.deleteScanItem(id);
  }

  @override
  Future<void> updateScanItem(int id, {required String serialNumber, required int quantity}) {
    return remoteDataSource.updateScanItem(id, serialNumber, quantity);
  }

  @override
  Future<List<Map<String, dynamic>>> getExportData(
      DateTime date, {
        required String bookingConfirmation,
      }) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return remoteDataSource.getExportData(dateStr, bookingConfirmation: bookingConfirmation);
  }

  @override
  Future<void> uploadExportFile(List<int> fileBytes, String fileName) {
    return remoteDataSource.uploadExportFile(fileBytes, fileName);
  }
}