import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'windows_local_firestore.dart';
import 'windows_receipt_print_dialog.dart';
import 'windows_print_layout.dart';

/// Compatibility entry point for existing native preview Print actions.
/// Opens the shared in-app print dialog; no browser tabs or saved temp files.
class WindowsBrowserPrint {
  static Future<void> open(BuildContext context, Uint8List pdf,
      {String title='Print document', bool Function()? isCurrent}) async {
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    bool current()=>db.activeProfileId==profile &&
      db.activeProfileIdentity['schoolSyncId']==school && (isCurrent?.call()??true);
    if(!context.mounted || !current())return;
    await showDialog<void>(context:context,builder:(_)=>WindowsReceiptPrintDialog(
      receipt:Future.value(pdf),title:title,subtitle:'Print preview',isCurrent:current));
  }

  static Future<void> openImages(BuildContext context,
    List<({Uint8List png, int width, int height})> pages,
    {String title='Print document',bool actualSize=false,bool Function()? isCurrent}
  ) async {
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId'];
    bool current()=>db.activeProfileId==profile &&
      db.activeProfileIdentity['schoolSyncId']==school && (isCurrent?.call()??true);
    if(!current())return;
    final pdf=await WindowsPrintLayout.fromImages(pages,actualSize:actualSize);
    if(!context.mounted||!current())return;
    await open(context,pdf,title:title,isCurrent:current);
  }
}
