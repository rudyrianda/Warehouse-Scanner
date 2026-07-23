import 'package:flutter/material.dart';

class CompactField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final FocusNode? focusNode;
  final TextInputType keyboardType;
  final bool isValid;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;

  const CompactField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
    this.keyboardType = TextInputType.text,
    this.isValid = true,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Colors.grey,
                letterSpacing: 0.5)),
        const SizedBox(height: 3),
        TextField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: keyboardType,
          textCapitalization: TextCapitalization.characters,
          readOnly: readOnly,
          style: TextStyle(
            fontSize: 11,
            color: isValid ? null : Colors.red,
          ),
          onTap: onTap,
          onChanged: onChanged,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}
