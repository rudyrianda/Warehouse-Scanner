import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../../data/datasources/warehouse_remote_datasource.dart';
import '../../data/repositories/warehouse_repository_impl.dart';
import '../../domain/entities/scanned_item.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../controllers/data_controller.dart';

class DataPage extends StatefulWidget {
  const DataPage({super.key});

  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  late final DataController _controller;

  @override
  void initState() {
    super.initState();
    final client = http.Client();
    final remoteDataSource = WarehouseRemoteDataSource(client: client);
    final repository = WarehouseRepositoryImpl(remoteDataSource: remoteDataSource);

    _controller = DataController(
      manageScanUseCase: ManageScanUseCase(repository),
    )..init();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showErrorPopup(int statusCode) async {
    final isDuplicate = statusCode == 409;
    final isWrongContainer = statusCode == 400;
    final headerColor = isDuplicate ? Colors.orange.shade700 : Colors.red.shade700;

    String titleText = 'QUANTITY PENUH!';
    if (isDuplicate) titleText = 'DUPLIKAT SERIAL!';
    if (isWrongContainer) titleText = 'SALAH CONTAINER!';

    await showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              color: headerColor,
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Column(
                children: [
                  Icon(
                    isDuplicate ? Icons.warning_amber_rounded : Icons.block_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    titleText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                _controller.lastMsg ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: headerColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    _controller.onErrorDialogClosed();
  }

  Future<void> _deleteItem(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus?', style: TextStyle(fontSize: 14)),
        content: const Text('Hapus data scan ini?', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _controller.deleteItem(id);
  }

Future<void> _editItem(ScannedItem item) async {
    final serialCtrl = TextEditingController(text: item.serialNumber);

    final saved = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (_) => AlertDialog(
        scrollable: true,
        title: const Text('Edit Item',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: serialCtrl,
              decoration: const InputDecoration(labelText: 'Serial Number', isDense: true),
              style: const TextStyle(fontSize: 13, color: Colors.black),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Simpan', style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );

    if (saved != true) return;
    await _controller.editItem(item.id, serialCtrl.text.trim(), item.quantity);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final pendingCode = _controller.lastStatusCode;
        if (pendingCode == 409 || pendingCode == 422 || pendingCode == 400) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final code = _controller.lastStatusCode;
            if (code == 409 || code == 422 || code == 400) {
              _showErrorPopup(code!);
            }
          });
        }

        // Seluruh isi page dibungkus SingleChildScrollView supaya gak overflow
        // berapa pun tinggi yang tersisa pas keyboard muncul (search box, dsb).
        // List scan-nya pakai shrinkWrap + NeverScrollableScrollPhysics karena
        // udah ikut scroll bareng SingleChildScrollView di luar.
        return SingleChildScrollView(
          child: Column(
            children: [
              // Container picker
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: DropdownButtonFormField<String>(
                  value: _controller.selectedContainer,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Container',
                    labelStyle: const TextStyle(fontSize: 13, color: Colors.black),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    suffixIcon: _controller.loadingContainers
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.5)),
                          )
                        : null,
                  ),
                  hint: Text(
                    _controller.containers.isEmpty
                        ? 'Belum ada container hari ini'
                        : '-- Pilih Container --',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                  items: _controller.containers
                      .map((c) => DropdownMenuItem<String>(
                            value: c['containerNumber'] as String?,
                            child: Text(c['containerNumber']?.toString() ?? '-',
                                style: const TextStyle(fontSize: 13, color: Colors.black)),
                          ))
                      .toList(),
                  onChanged: _controller.selectContainer,
                ),
              ),
              if (_controller.selectedContainer != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: DropdownButtonFormField<String>(
                    value: _controller.selectedDo,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'DO Number',
                      labelStyle: const TextStyle(fontSize: 13, color: Colors.black),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    hint: const Text(
                      '-- Pilih DO Number --',
                      style: TextStyle(fontSize: 13, color: Colors.black54),
                    ),
                    items: _controller.uniqueDosInContainer
                        .map((doNo) => DropdownMenuItem<String>(
                      value: doNo,
                      child: Text(doNo,
                          style: const TextStyle(fontSize: 13, color: Colors.black)),
                    ))
                        .toList(),
                    onChanged: _controller.selectDo,
                  ),
                ),
              // Model summary container
              if (_controller.containerDetailsByDo.isNotEmpty &&
                  MediaQuery.of(context).viewInsets.bottom == 0)
                Container(
                  margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Model dalam container:',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      ..._controller.containerDetailsByDo.map((d) {
                        final scanned = d['scannedToday'] as int? ?? 0;
                        final total = d['quantity'] as int? ?? 0;
                        final done = scanned >= total;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Row(
                            children: [
                              Icon(
                                done ? Icons.check_circle : Icons.radio_button_unchecked,
                                size: 10,
                                color: done ? Colors.green.shade600 : Colors.grey,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  '${d['model']} — $scanned/$total',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: done ? Colors.green.shade700 : Colors.black,
                                    fontWeight: done ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),

              // Scan input
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: TextField(
                  controller: _controller.scanCtrl,
                  focusNode: _controller.scanFocus,
                  autofocus: true,
                  keyboardType: TextInputType.none,
                  readOnly: _controller.selectedContainer == null || _controller.selectedDo == null,
                  onChanged: _controller.onScanChanged,
                  onSubmitted: (_) => _controller.submitScan(),
                  decoration: InputDecoration(
                    hintText: _controller.selectedContainer == null
                        ? 'Pilih container dulu untuk scan'
                        : (_controller.selectedDo == null
                        ? 'Pilih DO Number dulu untuk scan'
                        : 'Arahkan scanner...'),
                    hintStyle: const TextStyle(fontSize: 13, color: Colors.black54),
                    isDense: true,
                    filled: _controller.selectedContainer == null,
                    fillColor: Colors.grey.shade200,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  style: const TextStyle(fontSize: 13, color: Colors.black),
                ),
              ),

              // Feedback bar
              if (_controller.lastMsg != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _controller.lastSuccess ? Colors.green.shade50 : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _controller.lastSuccess ? Colors.green.shade200 : Colors.red.shade200,
                    ),
                  ),
                  child: Text(
                    _controller.lastMsg!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _controller.lastSuccess ? Colors.green.shade800 : Colors.red.shade800,
                    ),
                  ),
                ),

              // Search box
              if (_controller.selectedContainer != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
                  child: TextField(
                    onChanged: _controller.onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Cari serial / model...',
                      hintStyle: const TextStyle(fontSize: 11, color: Colors.black54),
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 14, color: Colors.black54),
                      prefixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      suffixIcon: _controller.searchQuery.isNotEmpty
                          ? InkWell(
                              onTap: _controller.clearSearch,
                              child: const Icon(Icons.close, size: 14, color: Colors.black54),
                            )
                          : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    style: const TextStyle(fontSize: 11, color: Colors.black),
                  ),
                ),

              // Table header
              Container(
                color: Colors.grey.shade300,
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: const Row(
                  children: [
                    Expanded(
                        flex: 3,
                        child: Text('Model',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black))),
                    Expanded(
                        flex: 2,
                        child: Text('Serial',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black))),
                    Expanded(
                        flex: 1,
                        child: Text('Qty',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black))),
                    SizedBox(width: 56),
                  ],
                ),
              ),

              // Rows
              _controller.filteredItems.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_outlined, size: 32, color: Colors.grey.shade400),
                            const SizedBox(height: 8),
                            Text(
                              _controller.selectedContainer == null
                                  ? 'Pilih container dulu'
                                  : 'Belum ada scan untuk container ini',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _controller.filteredItems.length,
                      itemBuilder: (_, i) {
                        final item = _controller.filteredItems[i];
                        return Container(
                          decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                            color: i.isEven ? null : Colors.grey.shade50,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                                  child: Text(item.model ?? '-',
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 10, color: Colors.black)),
                                ),
                              ),
                              Expanded(
                                flex: 2,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 5),
                                  child: Text(item.serialNumber ?? '-',
                                      textAlign: TextAlign.center,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 10, color: Colors.black)),
                                ),
                              ),
                              Expanded(
                                flex: 1,
                                child: Text(
                                  '${item.quantity}/${item.allowedQty}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: item.quantity >= item.allowedQty
                                        ? Colors.green.shade700
                                        : Colors.black,
                                    fontWeight: item.quantity >= item.allowedQty
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 56,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    InkWell(
                                      onTap: () => _editItem(item),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.edit, size: 14, color: Colors.blue),
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () => _deleteItem(item.id),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.delete_outline, size: 14, color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

              // Footer
              if (_controller.items.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  color: Colors.grey.shade100,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Total hari ini: ${_controller.filteredItems.length} item',
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: _controller.refreshAll,
                        child: const Icon(Icons.refresh, size: 14, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}