import '../../domain/entities/scanned_item.dart';

class ScannedItemModel extends ScannedItem {
  const ScannedItemModel({
    required super.id,
    super.model,
    super.serialNumber,
    required super.quantity,
    required super.allowedQty,
    super.scannedAt,
    super.doText,
    super.doNo,
  });

  factory ScannedItemModel.fromJson(Map<String, dynamic> json) =>
      ScannedItemModel(
        id: json['id'] as int,
        model: json['model'] as String?,
        serialNumber: json['serialNumber'] as String?,
        quantity: (json['scannedCount'] ?? json['quantity']) as int,
        allowedQty: json['allowedQty'] as int,
        scannedAt: json['scannedAt'] as String?,
        doText: json['doText'] as String?,
        doNo: json['doNo'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'model': model,
    'serialNumber': serialNumber,
    'quantity': quantity,
    'allowedQty': allowedQty,
    'scannedAt': scannedAt,
    'doText': doText,
    'doNo': doNo,
  };
}
