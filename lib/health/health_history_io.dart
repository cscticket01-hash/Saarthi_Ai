import 'dart:convert';
import 'dart:io';
import 'universal_health.dart';

/// Only sanitized guardian metadata, segregated by a hash of school/profile.
/// No application database, backup, source image or business queue is opened.
class FileHealthHistory implements HealthHistoryStore {
  FileHealthHistory(this.directory);
  final Future<Directory> Function() directory;
  Future<void> _tail = Future.value();
  Future<File> _file(HealthContext context) async {
    final root=await directory();
    return File('${root.path}/universal_health_2/${context.fingerprint}.json');
  }
  @override Future<List<HealthEvent>> load(HealthContext context) async {
    final file=await _file(context);
    if(!await file.exists()){
      if(await File('${file.path}.next').exists() || await File('${file.path}.previous').exists())throw const FormatException('Interrupted health history requires review');
      return [];
    }
    if(await file.length()>128*1024)throw const FormatException('Health history size bound');
    final value=jsonDecode(await file.readAsString());
    if(value is! Map || value['schema']!=2 || value['context']!=context.fingerprint || value['events'] is! List || (value['events'] as List).length>256)throw const FormatException('Health history identity unverified');
    final events=(value['events'] as List).map(HealthEvent.parse).toList();
    if(events.any((e)=>e==null))throw const FormatException('Health history event requires review');
    return events.cast<HealthEvent>();
  }
  @override Future<void> save(HealthContext context,List<HealthEvent> events) {
    final work=_tail.catchError((_){}).then((_) async {
      final file=await _file(context);
      final encoded=jsonEncode({'schema':2,'context':context.fingerprint,'events':events.take(256).map((e)=>e.toJson()).toList()});
      if(encoded.length>128*1024)throw StateError('Health history size bound');
      await file.parent.create(recursive:true);
      final tmp=File('${file.path}.next');
      await tmp.writeAsString(encoded,flush:true);
      if(await tmp.readAsString()!=encoded)throw StateError('Health history readback failed');
      // This is exclusively guardian metadata, never a school backup.
      if(await file.exists())await file.copy('${file.path}.previous');
      // Windows rename does not replace existing destinations reliably.
      await tmp.copy(file.path);
      if(await file.readAsString()!=encoded)throw StateError('Health history commit unverified');
    });
    _tail=work;
    return work;
  }
}
