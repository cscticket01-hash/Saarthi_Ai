import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_bulk_screen.dart';
import '../lib/id_card_bulk_job_store.dart';
import '../lib/id_card_manifest.dart';
import '../lib/id_card_school_source.dart';

class _DelayedJobs extends IdCardBulkJobStore {
  _DelayedJobs():super(rootPath:'unused-origin-test',schoolId:'synthetic');
  final result=Completer<List<Map<String,dynamic>>>();
  @override Future<List<Map<String,dynamic>>> listJobs()=>result.future;
}
void main(){
  testWidgets('late saved jobs cannot expose old school after origin changes',(tester)async{
    var current=true;
    final store=_DelayedJobs();
    final source=IdCardSchoolSource(schoolId:'synthetic',profile:{},connection:{},records:[{'_recordId':'private-person','class':'Private class'}],ensureActive:(){if(!current)throw StateError('School changed');});
    final manifest=IdCardManifest.fromJson(Map<String,dynamic>.from(jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync()) as Map));
    await tester.pumpWidget(MaterialApp(home:IdCardBulkScreen(source:source,template:manifest,store:store)));
    current=false;
    store.result.complete([{'jobId':'private-old-job','count':1,'status':'pending'}]);
    await tester.pump();
    expect(find.textContaining('private-old-job'),findsNothing);
    expect(find.textContaining('School changed; reopen ID tools'),findsOneWidget);
    expect(find.text('Private class'),findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
