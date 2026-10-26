// Review-only TEST website. Not a replacement for the developer portal.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'sync_review_school_console.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  runApp(const MaterialApp(home: SyncReviewSchoolConsole()));
}
