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

/// Separate diagnostic trend metadata; never the repair-admission ledger.
class FileHealthSamples implements HealthSampleStore {
  FileHealthSamples(this.directory);
  final Future<Directory> Function() directory;
  Future<File> file(HealthContext context) async => File('${(await directory()).path}/health_trends_2/${context.fingerprint}.json');
  @override
  Future<List<HealthSample>> loadSamples(HealthContext context) async {
    final target = await file(context);
    if (!await target.exists()) return [];
    if (await target.length() > 1024*1024) throw const FormatException('Trend budget');
    final raw = jsonDecode(await target.readAsString());
    if (raw is! Map || raw['context'] != context.fingerprint || raw['samples'] is! List ||
        (raw['samples'] as List).length > 10080) throw const FormatException('Trend scope');
    final result = <HealthSample>[];
    for (final row in raw['samples']) {
      if (row is! List || row.length != 2 || row[0] is! int ||
          row[1] != null && (row[1] is! int || row[1]<0 || row[1]>100)) throw const FormatException('Trend evidence');
      final at = DateTime.fromMillisecondsSinceEpoch(row[0]);
      if (result.isNotEmpty && !at.isAfter(result.last.at)) throw const FormatException('Trend chronology');
      result.add(HealthSample(at, row[1]));
    }
    return result;
  }
  @override
  Future<void> saveSamples(HealthContext context, List<HealthSample> samples) async {
    final target = await file(context);
    await target.parent.create(recursive:true);
    final encoded = jsonEncode({'context':context.fingerprint,
      'samples':samples.take(10080).map((s)=>[s.at.millisecondsSinceEpoch,s.score]).toList()});
    final staged = File('${target.path}.next');
    await staged.writeAsString(encoded, flush:true);
    await staged.copy(target.path);
  }
}
