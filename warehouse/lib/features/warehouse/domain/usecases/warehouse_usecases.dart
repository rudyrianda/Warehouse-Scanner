import '../repositories/warehouse_repository.dart';
import '../entities/scanned_item.dart';
import '../entities/entry_detail.dart';

class GetModelsUseCase {
  final WarehouseRepository repository;
  GetModelsUseCase(this.repository);

  Future<List<Map<String, String>>> call() => repository.getModels();
}

class SubmitEntryUseCase {
  final WarehouseRepository repository;
  SubmitEntryUseCase(this.repository);

  Future<void> submit({
    required DateTime date,
    required String containerNumber,
    required String? bookingConfirmation,
    required List<Map<String, dynamic>> items,
  }) =>
      repository.submitEntry(
        date: date,
        containerNumber: containerNumber,
        bookingConfirmation: bookingConfirmation,
        items: items,
      );

  Future<List<String>> getTodaySubmittedModels(DateTime date) =>
      repository.getTodaySubmittedModels(date);

  Future<List<EntryDetail>> fetchEntriesForDate(DateTime date) =>
      repository.fetchEntriesForDate(date);

  Future<void> updateEntryDetail(int detailId, Map<String, dynamic> payload) =>
      repository.updateEntryDetail(detailId, payload);
}

class ManageScanUseCase {
  final WarehouseRepository repository;
  ManageScanUseCase(this.repository);

  Future<List<Map<String, dynamic>>> getContainersToday() =>
      repository.getContainersToday();

  Future<List<Map<String, dynamic>>> getContainerDetails(String containerNumber) =>
      repository.getContainerDetails(containerNumber);

  Future<List<ScannedItem>> getScannedToday() =>
      repository.getScannedToday();

  Future<List<ScannedItem>> getScannedByContainer(String containerNumber) =>
      repository.getScannedByContainer(containerNumber);

  Future<Map<String, dynamic>> scan(
      String serialNumber,
      String containerNumber, {
        String? doNumber,
      }) =>
      repository.scanSerialNumber(
        serialNumber,
        containerNumber,
        doNumber: doNumber,
      );

  Future<void> deleteScan(int id) =>
      repository.deleteScanItem(id);

  Future<void> updateScan(int id,
      {required String serialNumber, required int quantity}) =>
      repository.updateScanItem(id,
          serialNumber: serialNumber, quantity: quantity);
}

class ExportDataUseCase {
  final WarehouseRepository repository;
  ExportDataUseCase(this.repository);

  Future<List<Map<String, dynamic>>> getContainersToday() =>
      repository.getContainersToday();

  Future<List<Map<String, dynamic>>> getBookingsToday() =>
      repository.getBookingsToday();

  // ← TAMBAH: dipakai ExportController untuk ambil DO unik per container
  Future<List<Map<String, dynamic>>> getContainerDetails(
      String containerNumber) =>
      repository.getContainerDetails(containerNumber);

  Future<List<Map<String, dynamic>>> getExportData(
      DateTime date, {
        required String bookingConfirmation,
      }) =>
      repository.getExportData(date, bookingConfirmation: bookingConfirmation);

  Future<void> uploadFile(List<int> fileBytes, String fileName) =>
      repository.uploadExportFile(fileBytes, fileName);
}
