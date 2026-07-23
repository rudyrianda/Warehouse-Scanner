import '../../domain/entities/entry_detail.dart';

class EntryDetailModel extends EntryDetail {
  const EntryDetailModel({
    required super.detailId,
    super.model,
    super.contNo,
    super.destination,
    super.drlNumber,
    super.doText,
    super.serialNumber,
    required super.quantity,
    required super.entryId,
  });

  factory EntryDetailModel.fromJson(Map<String, dynamic> json) =>
      EntryDetailModel(
        detailId: json['detailId'] as int,
        model: json['model'] as String?,
        contNo: json['contNo'] as String?,
        destination: json['destination'] as String?,
        drlNumber: json['drlNumber'] as String?,
        doText: json['doText'] as String?,
        serialNumber: json['serialNumber'] as String?,
        quantity: json['quantity'] as int? ?? 1,
        entryId: json['entryId'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'detailId': detailId,
        'model': model,
        'contNo': contNo,
        'destination': destination,
        'drlNumber': drlNumber,
        'doText': doText,
        'serialNumber': serialNumber,
        'quantity': quantity,
        'entryId': entryId,
      };
}
