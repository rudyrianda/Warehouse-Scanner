class ScannedItem {
  final int id;
  final String? model;
  final String? serialNumber;
  final int quantity;
  final int allowedQty;
  final String? scannedAt;
  final String? doText;
  final String? doNo;

  const ScannedItem({
    required this.id,
    this.model,
    this.serialNumber,
    required this.quantity,
    required this.allowedQty,
    this.scannedAt,
    this.doText,
    this.doNo,
  });
}
