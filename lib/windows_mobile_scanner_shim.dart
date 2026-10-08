import 'package:flutter/material.dart';

class Barcode {
  const Barcode({this.rawValue});
  final String? rawValue;
}

class BarcodeCapture {
  const BarcodeCapture({this.barcodes = const <Barcode>[]});
  final List<Barcode> barcodes;
}

class MobileScanner extends StatelessWidget {
  const MobileScanner({
    super.key,
    this.fit = BoxFit.cover,
    this.onDetect,
  });

  final BoxFit fit;
  final void Function(BarcodeCapture capture)? onDetect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0C171D),
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.qr_code_scanner_rounded,
            color: Color(0xFF00D9A5),
            size: 38,
          ),
          SizedBox(height: 10),
          Text(
            'Student scanner Windows Admin app me disabled hai.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
