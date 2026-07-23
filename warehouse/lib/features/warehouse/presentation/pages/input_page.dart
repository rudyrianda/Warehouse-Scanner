import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/compact_field.dart';
import '../../../../core/widgets/section_card.dart';
import '../../data/datasources/warehouse_remote_datasource.dart';
import '../../data/repositories/warehouse_repository_impl.dart';
import '../../domain/usecases/warehouse_usecases.dart';
import '../controllers/input_controller.dart';
import '../../data/datasources/local_database.dart';

class InputPage extends StatefulWidget {
  const InputPage({super.key});

  @override
  State<InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<InputPage> {
  late final InputController _controller;
  final FocusNode _modelFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final client = http.Client();
    final remoteDataSource = WarehouseRemoteDataSource(client: client);
    final repository = WarehouseRepositoryImpl(remoteDataSource: remoteDataSource);
    _controller = InputController(
      getModelsUseCase: GetModelsUseCase(repository),
    )..init();
  }

  @override
  void dispose() {
    _modelFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submitEntry() async {
    final error = await _controller.submitEntry();
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    } else {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (dialogCtx) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
          title: const Text('Submit Berhasil!', textAlign: TextAlign.center),
          content: const Text('Data berhasil disimpan', textAlign: TextAlign.center),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _onEnter() async {
    final modelText = _controller.modelCtrl.text.trim();
    final success = await _controller.onEnter();
    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Destination, DRL, dan Model wajib diisi')),
      );
      return;
    }

    final pendingCount = _controller.pendingItems.length;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('Item Ditambahkan', textAlign: TextAlign.center),
        content: Text('$pendingCount item pending\nModel: $modelText',
            textAlign: TextAlign.center),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _onEdit() async {
    await showDialog(
      context: context,
      builder: (context) => _EditEntryDialog(
        initialDate: _controller.selectedDate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              SectionCard(
                title: 'Booking & Container',
                child: Column(
                  children: [
                    CompactField(
                      controller: _controller.bookingCtrl,
                      label: 'Booking Confirmation',
                      readOnly: _controller.pendingItems.isNotEmpty,
                      onTap: _controller.pendingItems.isNotEmpty
                          ? null
                          : () => _controller.bookingCtrl.clear(),
                    ),
                    const SizedBox(height: 6),
                    CompactField(
                      controller: _controller.contCtrl,
                      label: 'Container Number',
                      readOnly: _controller.pendingItems.isNotEmpty,
                      onTap: _controller.pendingItems.isNotEmpty
                          ? null
                          : () => _controller.contCtrl.clear(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              SectionCard(
                title: 'Shipment Info',
                child: Column(
                  children: [
                    CompactField(
                      controller: _controller.destinationCtrl,
                      label: 'Destination',
                      onTap: () => _controller.destinationCtrl.clear(),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: CompactField(
                            controller: _controller.drlCtrl,
                            label: 'DRL Number',
                            onTap: () => _controller.drlCtrl.clear(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        //Expanded(
                          //child: CompactField(
                            //controller: _controller.doCtrl,
                            //label: 'DO',
                           // onTap: () => _controller.doCtrl.clear(),
                         // ),
                       // ),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: CompactField(
                                  controller: _controller.doCtrl,
                                  label: 'DO',
                                  onTap: () => _controller.doCtrl.clear(),
                                ),
                              ),
                              const SizedBox(width: 4),
                              // Tombol Baru untuk ganti ke DO Berikutnya
                              IconButton(
                                icon: const Icon(Icons.arrow_forward_rounded, color: Colors.blue),
                                tooltip: 'DO Berikutnya',
                                onPressed: () {
                                  if (_controller.doCtrl.text.isNotEmpty) {
                                    _controller.nextDoNumber();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('DO dikunci. Silakan masukkan DO Baru'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              SectionCard(
                title: 'Product Info',
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Model',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black54,
                                      letterSpacing: 0.5)),
                              const SizedBox(height: 3),
                              _controller.loadingModels
                                  ? const SizedBox(
                                      height: 48,
                                      child: Center(
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)),
                                    )
                                  : RawAutocomplete<String>(
                                      textEditingController: _controller.modelCtrl,
                                      focusNode: _modelFocusNode,
                                      optionsBuilder: (TextEditingValue textEditingValue) {
                                        if (textEditingValue.text.isEmpty) {
                                          return _controller.modelOptions;
                                        }
                                        return _controller.modelOptions.where((String option) {
                                          return option.toLowerCase().contains(textEditingValue.text.toLowerCase());
                                        });
                                      },
                                      onSelected: (String selection) {
                                        _controller.onModelChanged(selection);
                                      },
                                      fieldViewBuilder: (context, textEditingController, focusNode, onFieldSubmitted) {
                                        return TextFormField(
                                          controller: textEditingController,
                                          focusNode: focusNode,
                                          textCapitalization: TextCapitalization.characters,
                                          onFieldSubmitted: (val) => onFieldSubmitted(),
                                          style: const TextStyle(fontSize: 13, color: Colors.black),
                                          decoration: InputDecoration(
                                            isDense: true,
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(5)),
                                            filled: true,
                                            fillColor: Colors.white,
                                            hintText: 'Cari atau ketik Model',
                                            hintStyle: const TextStyle(fontSize: 13, color: Colors.black54),
                                            suffixIcon: const Icon(Icons.arrow_drop_down, color: Colors.black54, size: 18),
                                          ),
                                        );
                                      },
                                      optionsViewBuilder: (context, onSelected, options) {
                                        return Align(
                                          alignment: Alignment.topLeft,
                                          child: Material(
                                            elevation: 4.0,
                                            borderRadius: BorderRadius.circular(5),
                                            child: Container(
                                              width: MediaQuery.of(context).size.width * 0.45,
                                              constraints: const BoxConstraints(maxWidth: 300, maxHeight: 110),
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius: BorderRadius.circular(5),
                                                border: Border.all(color: Colors.grey.shade300),
                                              ),
                                              child: ListView.builder(
                                                padding: EdgeInsets.zero,
                                                shrinkWrap: true,
                                                itemCount: options.length,
                                                itemBuilder: (BuildContext context, int index) {
                                                  final String option = options.elementAt(index);
                                                  return InkWell(
                                                    onTap: () => onSelected(option),
                                                    child: Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                                      color: Colors.white,
                                                      child: Text(
                                                        option,
                                                        style: const TextStyle(fontSize: 13, color: Colors.black),
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Quantity',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black54,
                                      letterSpacing: 0.5)),
                              const SizedBox(height: 3),
                              _QuantityRow(
                                controller: _controller.qtyCtrl,
                                value: _controller.quantity,
                                onChanged: (value) => _controller.updateQuantityDirect(value),
                                onDecrement: () => _controller.adjustQuantity(-1),
                                onIncrement: () => _controller.adjustQuantity(1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _onEnter,
                        style: OutlinedButton.styleFrom(
                          backgroundColor: AppTheme.lightBlue,
                          side: const BorderSide(color: AppTheme.borderBlue),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6)),
                        ),
                        icon: const Icon(Icons.keyboard_return,
                            size: 13, color: AppTheme.primaryBlue),
                        label: const Text('Enter',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlue)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _controller.submitting ? null : _submitEntry,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: _controller.submitting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.save, size: 13, color: Colors.white),
                      label: Text(
                        _controller.submitting
                            ? 'Submitting...'
                            : 'Submit (${_controller.pendingItems.length})',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _onEdit,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: const Icon(Icons.edit, size: 13),
                      label: const Text('Edit',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QuantityRow extends StatelessWidget {
  final int value;
  final TextEditingController controller;
  final ValueChanged<int> onChanged;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  const _QuantityRow({
    required this.controller,
    required this.value,
    required this.onChanged,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          _QtyBtn(icon: Icons.remove, onTap: onDecrement),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              onChanged: (text) {
                final parsed = int.tryParse(text);
                if (parsed != null) onChanged(parsed.clamp(1, 9999));
              },
            ),
          ),
          _QtyBtn(icon: Icons.add, onTap: onIncrement),
        ],
      ),
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: double.infinity,
        color: Colors.grey.shade200,
        child: Icon(icon, size: 14),
      ),
    );
  }
}

class _EditEntryDialog extends StatefulWidget {
  final DateTime initialDate;

  const _EditEntryDialog({
    required this.initialDate,
  });

  @override
  State<_EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends State<_EditEntryDialog> {
  late DateTime _pickedDate;
  bool _loading = false;
  String? _errorMsg;

  List<Map<String, dynamic>> _allDetails = [];
  Map<String, dynamic>? _selectedDetail;

  final _modelCtrl = TextEditingController();
  final _contCtrl = TextEditingController();
  final _destinationCtrl = TextEditingController();
  final _drlCtrl = TextEditingController();
  final _doCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _pickedDate = widget.initialDate;
    _fetchEntriesForDate();
  }

  @override
  void dispose() {
    _modelCtrl.dispose();
    _contCtrl.dispose();
    _destinationCtrl.dispose();
    _drlCtrl.dispose();
    _doCtrl.dispose();
    _serialCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchEntriesForDate() async {
    setState(() {
      _loading = true;
      _errorMsg = null;
      _allDetails = [];
      _selectedDetail = null;
      _clearFields();
    });

    try {
      final rawDetails = await LocalDatabase.getAllDetailsByDate(
        _pickedDate.toIso8601String().substring(0, 10),
      );

      setState(() {
        _loading = false;
        if (rawDetails.isEmpty) {
          _errorMsg = 'Tidak ada data untuk tanggal ini';
        } else {
          _allDetails = rawDetails
              .map((d) => Map<String, dynamic>.from(d))
              .toList();
        }
      });
    } catch (e) {
      setState(() {
        _errorMsg = 'Error: $e';
        _loading = false;
      });
    }
  }

  void _onDetailSelected(Map<String, dynamic>? detail) {
    if (detail == null) return;
    setState(() {
      _selectedDetail = detail;
      _modelCtrl.text       = detail['model']        ?? '';
      _contCtrl.text        = detail['contNo']       ?? '';
      _destinationCtrl.text = detail['destination']  ?? '';
      _drlCtrl.text         = detail['drlNumber']    ?? '';
      _doCtrl.text          = detail['doText']       ?? '';
      _serialCtrl.text      = detail['serialNumber'] ?? '';
      _qtyCtrl.text         = '${detail['quantity'] ?? 1}';
    });
  }

  void _clearFields() {
    _modelCtrl.clear();
    _contCtrl.clear();
    _destinationCtrl.clear();
    _drlCtrl.clear();
    _doCtrl.clear();
    _serialCtrl.clear();
    _qtyCtrl.clear();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _pickedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && picked != _pickedDate) {
      setState(() => _pickedDate = picked);
      _fetchEntriesForDate();
    }
  }

  Future<void> _submitEdit() async {
    if (_selectedDetail == null) return;

    final detailId = _selectedDetail!['id'] as int?;
    if (detailId == null) return;

    final qty = int.tryParse(_qtyCtrl.text) ?? 1;

    setState(() => _submitting = true);
    try {
      final payload = {
        'model':        _modelCtrl.text.trim(),
        'contNo':       _contCtrl.text.trim(),
        'destination':  _destinationCtrl.text.trim(),
        'drlNumber':    _drlCtrl.text.trim(),
        'doText':       _doCtrl.text.trim(),
        'serialNumber': _serialCtrl.text.trim(),
        'quantity':     qty.clamp(1, 9999),
      };

      await LocalDatabase.updateDetail(detailId, payload);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Data berhasil diupdate'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.94),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Edit Entry',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade400),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                        const SizedBox(width: 8),
                        Text(
                          '${_pickedDate.day.toString().padLeft(2, '0')}/'
                          '${_pickedDate.month.toString().padLeft(2, '0')}/'
                          '${_pickedDate.year}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        const Text('Ganti Tanggal',
                            style: TextStyle(fontSize: 10, color: Colors.blue)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (_loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_errorMsg != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Text(_errorMsg!,
                        style: const TextStyle(fontSize: 12, color: Colors.orange),
                        textAlign: TextAlign.center),
                  )
                else ...[
                  const Text('Pilih Model',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.black54,
                          letterSpacing: 0.5)),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    value: _selectedDetail,
                    isExpanded: true,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    hint: const Text('-- Pilih model --',
                        style: TextStyle(fontSize: 13)),
                    items: _allDetails.map((d) {
                      return DropdownMenuItem<Map<String, dynamic>>(
                        value: d,
                        child: Text(
                          '${d['model'] ?? '-'} (Qty: ${d['quantity']})',
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: _onDetailSelected,
                  ),
                  const SizedBox(height: 10),
                  if (_selectedDetail != null) ...[
                    _buildLabel('Model'),
                    _buildField(_modelCtrl),
                    const SizedBox(height: 6),
                    _buildLabel('Container No'),
                    _buildField(_contCtrl),
                    const SizedBox(height: 6),
                    _buildLabel('Destination'),
                    _buildField(_destinationCtrl),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('DRL Number'),
                              _buildField(_drlCtrl),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('DO'),
                              _buildField(_doCtrl),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _buildLabel('Serial Number'),
                    _buildField(_serialCtrl),
                    const SizedBox(height: 6),
                    _buildLabel('Quantity'),
                    _buildField(_qtyCtrl, keyboardType: TextInputType.number),
                    const SizedBox(height: 12),
                  ],
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: (_selectedDetail == null || _submitting)
                          ? null
                          : _submitEdit,
                      child: _submitting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Submit'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.black54,
              letterSpacing: 0.5)),
    );
  }

  Widget _buildField(TextEditingController ctrl,
      {TextInputType? keyboardType}) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }
}