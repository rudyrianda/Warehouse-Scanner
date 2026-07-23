import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import '../../../../core/theme/app_theme.dart';
import '../../data/datasources/warehouse_remote_datasource.dart';
import '../../data/repositories/warehouse_repository_impl.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../controllers/export_controller.dart';

class ExportPage extends StatefulWidget {
  const ExportPage({super.key});

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  late final ExportController _controller;

  @override
  void initState() {
    super.initState();
    final client = http.Client();
    final remoteDataSource = WarehouseRemoteDataSource(client: client);
    final repository = WarehouseRepositoryImpl(remoteDataSource: remoteDataSource);

    _controller = ExportController(
      exportDataUseCase: ExportDataUseCase(repository),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _controller.selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      _controller.updateDate(picked);
    }
  }

  Future<void> _export({bool forceExport = false}) async {
    final results = await _controller.exportAll(forceExport: forceExport);
    if (!mounted) return;

    if (results.length == 1 && results.first['requiresConfirmation'] == true) {
      final duplicates = (results.first['duplicates'] as List).cast<String>();
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
          title: const Text('Ditemukan Data Duplikat!', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Terdapat data duplikat lintas-hari yang terdeteksi sebelum export. Jika Anda tetap lanjut, data ini akan diberi tanda kuning di Excel.', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              const Text('Daftar Serial Bermasalah:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    duplicates.join('\n\n'),
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Batal & Perbaiki', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              onPressed: () {
                Navigator.pop(context);
                _export(forceExport: true);
              },
              child: const Text('Tetap Export', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      return;
    }

    // Tampilkan summary semua container
    final success = results.where((r) => r['success'] == true).toList();
    final failed  = results.where((r) => r['success'] != true).toList();

    final buffer = StringBuffer();
    if (success.isNotEmpty) {
      buffer.writeln('Berhasil Export No Booking order: ');
      for (final r in success) buffer.writeln('- ${r['booking']}');
    }
    if (failed.isNotEmpty) {
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln('❌ Gagal (${failed.length}):');
      for (final r in failed) buffer.writeln('  • ${r['booking']}: ${r['message']}');
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        iconPadding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        icon: Icon(
          failed.isEmpty ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
          color: failed.isEmpty ? Colors.green : Colors.orange,
          size: 32,
        ),
        title: Text(
          failed.isEmpty ? 'Export Berhasil' : 'Export Selesai',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
        ),
        content: Text(
          buffer.toString().trim(),
          style: const TextStyle(fontSize: 12, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'success':
        return const Icon(Icons.check_circle, size: 14, color: Colors.green);
      case 'failed':
        return const Icon(Icons.cancel, size: 14, color: Colors.red);
      case 'processing':
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.blue),
        );
      default:
        return Icon(Icons.circle_outlined, size: 14, color: Colors.grey.shade400);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final dateLabel = DateFormat('dd-MM-yyyy').format(_controller.selectedDate);

        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.file_download_outlined,
                      size: 40, color: AppTheme.primaryBlue),
                  const SizedBox(height: 10),
                  const Text('Export Data',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black)),
                  const SizedBox(height: 6),
                  const Text(
                    'Pilih tanggal lalu tekan Export.\nSemua Booking Confirmation akan diekspor otomatis.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 16),

                  // Date picker
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today, size: 14),
                    label: Text('Tanggal: $dateLabel',
                        style: const TextStyle(fontSize: 13, color: Colors.black)),
                  ),
                  const SizedBox(height: 16),

                  // Checklist progres per booking saat loading
                  if (_controller.loading && _controller.bookingStatus.isNotEmpty) ...[
                    if (_controller.currentProcessing != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Memproses: ${_controller.currentProcessing}',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
                        ),
                      ),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _controller.bookingStatus.length,
                        itemBuilder: (context, index) {
                          final item = _controller.bookingStatus[index];
                          final status = item['status'] as String;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                _statusIcon(status),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize:  MainAxisSize.min,
                                    children: [
                                      Text(
                                        item['booking'] as String,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold, // Dibuat tebal agar booking terlihat jelas
                                            color: Colors.black87
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        'DO: ${item['doText'] ?? '-'}',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey.shade600, // Warna abu-abu sebagai pembeda subtitle
                                            fontWeight: FontWeight.w500
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ]
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Export button
                  ElevatedButton.icon(
                    onPressed: _controller.loading ? null : _export,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                    icon: _controller.loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5, color: Colors.white))
                        : const Icon(Icons.download, size: 16, color: Colors.white),
                    label: Text(
                      _controller.loading ? 'Memproses...' : 'Export Excel',
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}