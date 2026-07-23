class EntryDetail {
  final int detailId;
  final String? model;
  final String? contNo;
  final String? destination;
  final String? drlNumber;
  final String? doText;
  final String? serialNumber;
  final int quantity;
  final int entryId;

  const EntryDetail({
    required this.detailId,
    this.model,
    this.contNo,
    this.destination,
    this.drlNumber,
    this.doText,
    this.serialNumber,
    required this.quantity,
    required this.entryId,
  });
}
