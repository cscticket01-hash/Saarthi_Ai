import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'storage/windows_sqlite_store.dart';
import 'windows_backup_integrity.dart';

/// Only a fresh local installation may activate a sealed, school-bound backup.
/// Authentication is supplied by the existing central login, never by backup data.
class WindowsCleanInstallRecovery {
  WindowsCleanInstallRecovery({required this.controlDirectory,
    required this.currentDataDirectory, required this.authenticateSchool});
  final Directory controlDirectory, currentDataDirectory;
  final Future<String> Function() authenticateSchool;
  File get _journal => File('${controlDirectory.path}/clean_install_recovery_v1.json');
  File get _pointer => File('${controlDirectory.path}/storage_config_v1.json');
  static final _busy = <String>{};

  Future<bool> isFreshInstallation() async {
    final school = await authenticateSchool();
    _school(school);
    for (final name in ['local_database_v1.json.pending']) {
      final file = File('${currentDataDirectory.path}/$name');
      if (await file.exists() && await file.length() > 0) return false;
    }
    final files = ['local_database_v1.json','local_database_v1.json.bak',WindowsSqliteStore.databaseName];
    if (files.any((name)=>File('${currentDataDirectory.path}/$name').existsSync())) {
      try {
        final roots = _readRoots(currentDataDirectory);
        for (final root in roots.values) {
          if (root['collections'] != null || root['profiles'] is! Map) return false;
          for (final profile in (root['profiles'] as Map).values) {
            if (profile is! Map || profile['identity'] is! Map || profile['collections'] is! Map) return false;
            final identity = profile['identity'] as Map;
            if (identity['schoolSyncId'] != school ||
                identity['schoolId'] != null && identity['schoolId'] != school) return false;
            // Even one setting, tombstone, receipt, deletion or queue item makes
            // the installation nonempty. No financial exemption or merging.
            for (final records in (profile['collections'] as Map).values) {
              if (records is! Map || records.isNotEmpty) return false;
            }
          }
        }
      } catch (_) { return false; }
    }
    final media = Directory('${currentDataDirectory.path}/LocalFiles');
    if (await FileSystemEntity.type(media.path,followLinks:false) == FileSystemEntityType.link) return false;
    if (await media.exists() && !await media.list().isEmpty) return false;
    return true;
  }

  Future<Map<String,dynamic>> prepare(Directory backup, Directory staging,
      {Future<void> Function(int)? onFileVerified}) async {
    final key=controlDirectory.absolute.path;
    if(!_busy.add(key)) throw StateError('Recovery already in progress.');
    try { return await _prepare(backup,staging,onFileVerified:onFileVerified); }
    finally { _busy.remove(key); }
  }

  Future<Map<String,dynamic>> _prepare(Directory backup, Directory staging,
      {Future<void> Function(int)? onFileVerified}) async {
    final school = await authenticateSchool();
    _school(school);
    if (!await isFreshInstallation()) throw StateError('Existing school data retained. Restore requires a fresh installation.');
    await controlDirectory.create(recursive:true);
    final sourcePath=(await backup.resolveSymbolicLinks()).replaceAll(r'\','/').toLowerCase();
    final controlPath=(await controlDirectory.resolveSymbolicLinks()).replaceAll(r'\','/').toLowerCase();
    if(controlPath==sourcePath || controlPath.startsWith('$sourcePath/')) throw StateError('Recovery journal must remain outside the sealed backup.');
    final currentPath=(await currentDataDirectory.resolveSymbolicLinks()).replaceAll(r'\','/').toLowerCase();
    final stageParent=(await staging.parent.resolveSymbolicLinks()).replaceAll(r'\','/').toLowerCase();
    final stageName=staging.uri.pathSegments.where((p)=>p.isNotEmpty).last.toLowerCase();
    final stagePath='$stageParent/$stageName';
    if(stagePath==currentPath || stagePath.startsWith('$currentPath/') || currentPath.startsWith('$stagePath/')) throw StateError('Choose staging outside the current application storage.');
    final sourceFiles = await WindowsBackupIntegrity.verify(backup);
    final allowedRoot={'local_database_v1.json','local_database_v1.json.bak',WindowsSqliteStore.databaseName,WindowsBackupIntegrity.manifestName};
    await for(final entity in backup.list(followLinks:false)) {
      final name=entity.uri.pathSegments.where((p)=>p.isNotEmpty).last;
      if(entity is File && !allowedRoot.contains(name) || entity is Directory && name!='LocalFiles') throw StateError('Unexpected backup contents require review.');
    }
    final roots = _readRoots(backup);
    final proof = _inspect(roots, school, backup);
    final sourceManifest = (await sha256.bind(File('${backup.path}/${WindowsBackupIntegrity.manifestName}').openRead()).first).toString();
    if (await _journal.exists()) {
      final old = await _readJournal();
      if (old['schoolId'] != school || old['sourceManifest'] != sourceManifest || old['staging'] != staging.absolute.path) {
        throw StateError('Another recovery journal is retained. Resume its original backup.');
      }
      if (['switching','active','verifiedAfterRestart','rolledBack'].contains(old['state'])) throw StateError('Existing activation retained. Reopen the app to recover or review.');
      if (old['state']=='prepared') {
        await _verifyPrepared(old);
        return old;
      }
    }
    final journal = <String,dynamic>{'version':1,'schoolId':school,
      'sourceManifest':sourceManifest,'source':backup.absolute.path,
      'staging':staging.absolute.path,'state':'copying','sourceFiles':sourceFiles,
      'recordCount':proof['recordCount'],'pendingCount':proof['pendingCount'],
      'documentPendingCount':proof['documentPendingCount'],'restorePendingCount':proof['restorePendingCount'],
      'semanticHash':proof['semanticHash']};
    await _writeJournal(journal);
    await WindowsBackupIntegrity.resumeRestore(backup, staging,onFileVerified:onFileVerified);
    // Source remains sealed/read-only. Only the copied generation is rebased.
    final stagedRoots = _readRoots(staging);
    final mappings = <String,String>{};
    dynamic rebase(dynamic value) {
      if (value is Map) return value.map((k,v)=>MapEntry(k,rebase(v)));
      if (value is List) return value.map(rebase).toList();
      if (value is String) {
        final relative = _mediaRelative(value);
        if (relative != null) {
          final path = '${staging.absolute.path}/${relative.replaceAll('/',Platform.pathSeparator)}';
          final output = value.startsWith('file:') ? Uri.file(path,windows:Platform.isWindows).toString() : path;
          mappings[value] = output;
          return output;
        }
      }
      return value;
    }
    for (final entry in stagedRoots.entries) {
      final changed = Map<String,dynamic>.from(rebase(entry.value) as Map);
      if (entry.key.endsWith('.sqlite')) {
        // The staged copy is the only writable SQLite connection.
        final store = await WindowsSqliteStore.open('${staging.path}/${entry.key}');
        try { await store.writeRoot(changed); await store.verify(); } finally { await store.close(); }
      } else {
        await File('${staging.path}/${entry.key}').writeAsString(jsonEncode(changed),flush:true);
      }
    }
    final stagedProof = _inspect(_readRoots(staging), school, staging);
    if (stagedProof['semanticHash'] != proof['semanticHash']) throw StateError('Recovered record identity differs. Activation blocked.');
    await WindowsBackupIntegrity.seal(staging);
    journal.addAll({'state':'prepared','pathMappings':mappings,
      'stagedManifest':(await sha256.bind(File('${staging.path}/${WindowsBackupIntegrity.manifestName}').openRead()).first).toString()});
    await _writeJournal(journal);
    await WindowsBackupIntegrity.verify(backup);
    await _verifyPrepared(journal);
    return journal;
  }

  /// Must be called while normal local storage/sync connections are closed.
  Future<void> activate({required bool administratorConfirmed,
      Future<void> Function(String stage)? checkpoint}) async {
    if (!administratorConfirmed) throw StateError('Administrator confirmation required.');
    final school = await authenticateSchool();
    final key = controlDirectory.absolute.path;
    if (!_busy.add(key)) throw StateError('Recovery activation already in progress.');
    try {
      final journal = await _readJournal();
      if (journal['schoolId'] != school) throw StateError('Authenticated school changed. Activation blocked.');
      if (journal['state'] == 'active') { await _verifyPrepared(journal); return; }
      if (journal['state'] != 'prepared' || !await isFreshInstallation()) throw StateError('Existing data or unfinished activation retained. Recover before retry.');
      await _verifyPrepared(journal);
      if(await FileSystemEntity.type(_pointer.path,followLinks:false)==FileSystemEntityType.link) throw StateError('Storage pointer requires review.');
      final previous = File('${_pointer.path}.clean-install-previous');
      if (await previous.exists()) throw StateError('Previous recovery pointer retained for review.');
      journal['previousPointer'] = await _pointer.exists() ? await _pointer.readAsString() : null;
      journal['state'] = 'switching';
      await _writeJournal(journal);
      final pending = File('${_pointer.path}.clean-install-pending');
      await pending.writeAsString(jsonEncode({'dataPath':journal['staging'],
        'schoolId':school,'recoveryManifest':journal['stagedManifest']}),flush:true);
      if (await _pointer.exists()) await _pointer.rename(previous.path);
      if (checkpoint != null) await checkpoint('previous_retained');
      await pending.rename(_pointer.path);
      if (checkpoint != null) await checkpoint('pointer_switched');
      await _verifyPrepared(journal);
      journal['state'] = 'active';
      await _writeJournal(journal);
    } finally { _busy.remove(key); }
  }

  /// Run before storage initialization. An interrupted pointer switch is either
  /// fully verified or rolled back; no database or queue is removed.
  Future<String?> recoverInterruptedActivation() async {
    if (!await _journal.exists() && !await File('${_journal.path}.previous').exists() && !await File('${_journal.path}.pending').exists()) return null;
    final journal = await _readJournal();
    if (!['switching','active'].contains(journal['state'])) return journal['state'] as String;
    try {
      if (await authenticateSchool() != journal['schoolId']) throw StateError('School authentication changed.');
      await _verifyPrepared(journal);
      final pointer = await _pointer.exists() ? jsonDecode(await _pointer.readAsString()) : null;
      if (pointer is! Map || pointer['dataPath'] != journal['staging'] || pointer['recoveryManifest'] != journal['stagedManifest']) throw StateError('Storage switch incomplete.');
      journal['state'] = 'verifiedAfterRestart';
      await _writeJournal(journal);
      return 'active';
    } catch (_) {
      // Retain a failed pointer for diagnosis. Previous usable storage wins.
      if (await _pointer.exists()) {
        await _pointer.rename('${_pointer.path}.rejected-${DateTime.now().microsecondsSinceEpoch}');
      }
      final previous = File('${_pointer.path}.clean-install-previous');
      if (await previous.exists()) {
        await previous.copy(_pointer.path);
      } else if (journal['previousPointer'] is String) {
        await _pointer.writeAsString(journal['previousPointer'] as String,flush:true);
      }
      journal['state'] = 'rolledBack';
      await _writeJournal(journal);
      return 'rolledBack';
    }
  }

  Future<void> _verifyPrepared(Map<String,dynamic> journal) async {
    final root = Directory(journal['staging'] as String);
    await WindowsBackupIntegrity.verify(root);
    final digest = (await sha256.bind(File('${root.path}/${WindowsBackupIntegrity.manifestName}').openRead()).first).toString();
    if (digest != journal['stagedManifest']) throw StateError('Staged backup generation changed.');
    final proof = _inspect(_readRoots(root),journal['schoolId'] as String,root);
    if (proof['semanticHash'] != journal['semanticHash'] || proof['recordCount'] != journal['recordCount'] || proof['pendingCount'] != journal['pendingCount'] || proof['documentPendingCount'] != journal['documentPendingCount'] || proof['restorePendingCount'] != journal['restorePendingCount']) throw StateError('Staged records changed.');
  }

  Future<Map<String,dynamic>> _readJournal() async {
    // Recover a journal rename interrupted before its pending replacement.
    if (!await _journal.exists()) {
      final pending=File('${_journal.path}.pending'), previous=File('${_journal.path}.previous');
      if(await pending.exists()) {
        await pending.copy(_journal.path);
      } else if(await previous.exists()) {
        await previous.copy(_journal.path);
      }
    }
    if (await FileSystemEntity.type(_journal.path,followLinks:false) != FileSystemEntityType.file || await _journal.length()>10*1024*1024) throw StateError('Recovery journal requires review.');
    final value = jsonDecode(await _journal.readAsString());
    if (value is! Map || value['version'] != 1) throw StateError('Invalid recovery journal.');
    return Map<String,dynamic>.from(value);
  }
  Future<void> _writeJournal(Map<String,dynamic> journal) async {
    final pending=File('${_journal.path}.pending'), previous=File('${_journal.path}.previous');
    await pending.writeAsString(jsonEncode(journal),flush:true);
    if(await previous.exists()) await previous.delete();
    if(await _journal.exists()) await _journal.rename(previous.path);
    await pending.rename(_journal.path);
  }

  static void _school(String school) {
    if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)) throw StateError('Central school authentication required.');
  }
  static Map<String,Map<String,dynamic>> _readRoots(Directory folder) {
    final roots=<String,Map<String,dynamic>>{};
    for(final name in ['local_database_v1.json','local_database_v1.json.bak',WindowsSqliteStore.databaseName]) {
      final file=File('${folder.path}/$name');
      if(!file.existsSync()) continue;
      if(name.endsWith('.sqlite')) {
        final db=sqlite3.open(file.path,mode:OpenMode.readOnly);
        try {
          if(db.select('PRAGMA quick_check').any((r)=>r.values.first!='ok') || db.select('PRAGMA foreign_key_check').isNotEmpty || db.select('PRAGMA user_version').single.values.first != 1) throw StateError('Backup SQLite integrity requires review.');
          final root=Map<String,dynamic>.from(jsonDecode(db.select("SELECT value FROM metadata WHERE key='root'").single['value'] as String) as Map);
          final profiles=<String,dynamic>{};
          for(final row in db.select('SELECT id,content FROM profiles')) {
            final id=row['id'] as String;
            final profile=Map<String,dynamic>.from(jsonDecode(row['content'] as String) as Map);
            final collections=<String,dynamic>{};
            for(final collection in db.select('SELECT name FROM collections WHERE profile=?',[id])) {
              final name=collection['name'] as String;
              collections[name]={for(final record in db.select('SELECT id,content FROM records WHERE profile=? AND collection=?',[id,name])) record['id'] as String:jsonDecode(record['content'] as String)};
            }
            profiles[id]={...profile,'collections':collections};
          }
          root['profiles']=profiles;
          roots[name]=root;
        } finally {db.close();}
      } else {
        final value=jsonDecode(file.readAsStringSync());
        if(value is! Map) throw StateError('Backup JSON requires review.');
        roots[name]=Map<String,dynamic>.from(value);
      }
    }
    if(roots.isEmpty) throw StateError('No supported local school database in backup.');
    return roots;
  }

  static Map<String,dynamic> _inspect(Map<String,Map<String,dynamic>> roots,String school,Directory folder) {
    _school(school);
    var count=0,pending=0,documentsPending=0,restoresPending=0;
    dynamic normalize(dynamic value) {
      if(value is Map) {
        for(final key in ['schoolId','schoolSyncId']) {
          if(value[key]!=null && value[key]!='' && value[key]!=school) throw StateError('Foreign school backup blocked.');
        }
        final keys=value.keys.map((e)=>e.toString()).toList()..sort();
        for(final key in keys) {
          final raw=value[key];
          if(raw is String && {'localPath','originalPath','optimizedPath','processedPath','photoPath','cachePath','filePath'}.contains(key) && raw.isNotEmpty && !raw.startsWith('http:') && !raw.startsWith('https:') && !raw.startsWith('data:') && _mediaRelative(raw)==null) throw StateError('Local media outside supported backup storage requires review.');
        }
        return {for(final key in keys) key:normalize(value[key])};
      }
      if(value is List) return value.map(normalize).toList();
      if(value is String) {
        final relative=_mediaRelative(value);
        if(relative!=null) {
          final file=File('${folder.path}/$relative');
          if(!file.existsSync()) throw StateError('Referenced local media missing from backup.');
          return relative;
        }
      }
      return value;
    }
    final normalized=<String,dynamic>{};
    final authoritativeName=roots.containsKey(WindowsSqliteStore.databaseName) ? WindowsSqliteStore.databaseName : roots.containsKey('local_database_v1.json') ? 'local_database_v1.json' : 'local_database_v1.json.bak';
    for(final entry in roots.entries) {
      final authoritative=entry.key==authoritativeName;
      final profiles=entry.value['profiles'];
      if(profiles is! Map || profiles.isEmpty || entry.value['collections']!=null) throw StateError('Unbound legacy backup requires explicit migration.');
      final operations=<String>{}, recordIdentities=<String>{};
      for(final raw in profiles.values) {
        if(raw is! Map || raw['identity'] is! Map || (raw['identity'] as Map)['schoolSyncId']!=school || raw['collections'] is! Map) throw StateError('Backup profile does not match authenticated school.');
        for(final collection in (raw['collections'] as Map).entries) {
          if(collection.value is! Map) throw StateError('Backup collection invalid.');
          for(final recordEntry in (collection.value as Map).entries) {
            final record=recordEntry.value;
            if(!recordIdentities.add(jsonEncode([collection.key,recordEntry.key]))) throw StateError('Duplicate school record across backup profiles requires review.');
            if(record is! Map) throw StateError('Backup record invalid.');
            if(authoritative) count++;
            if(collection.key=='_windows_firebase_outbox') {
              final operation=record['operationId'];
              if(operation is! String || operation.isEmpty || !operations.add(operation) || record['schoolId']!=school) throw StateError('Duplicate or unbound pending operation blocked.');
              if(authoritative) pending++;
            } else if(collection.key=='_windows_document_outbox') {
              // Document generation identity is its documentRevision plus its
              // unchanged map key; this pipeline has no generic operationId.
              if(record['schoolId']!=school || recordEntry.key is! String ||
                  (recordEntry.key as String).isEmpty || record['documentRevision'] is! String ||
                  (record['documentRevision'] as String).isEmpty ||
                  record['deleted']!=true && (record['localPath'] is! String || (record['localPath'] as String).isEmpty)) {
                throw StateError('Unbound document generation requires review.');
              }
              if(authoritative) documentsPending++;
            } else if(collection.key=='_windows_recycle_requests' && record['localRestore']==true) {
              if(record['schoolId']!=school || record['operationId'] is! String ||
                  (record['operationId'] as String).isEmpty || record['deletionOperationId'] is! String ||
                  (record['deletionOperationId'] as String).isEmpty || record['administratorApproved']!=true) {
                throw StateError('Unbound retained restore operation requires review.');
              }
              final snapshots=(raw['collections'] as Map)['_windows_local_deletions'];
              final snapshot=snapshots is Map ? snapshots[record['deletionOperationId']] : null;
              if(snapshot is! Map || snapshot['schoolId']!=school || snapshot['operationId']!=record['deletionOperationId']) {
                throw StateError('Original deletion evidence missing from backup.');
              }
              if(authoritative && record['state']!='verified') restoresPending++;
            }
          }
        }
      }
      normalized[entry.key]=normalize(entry.value);
    }
    if(normalized.containsKey(WindowsSqliteStore.databaseName) && normalized.containsKey('local_database_v1.json')) {
      final sqliteProfiles=(normalized[WindowsSqliteStore.databaseName] as Map)['profiles'];
      final jsonProfiles=(normalized['local_database_v1.json'] as Map)['profiles'];
      if(jsonEncode(sqliteProfiles)!=jsonEncode(jsonProfiles)) throw StateError('SQLite and JSON backup generations disagree. Explicit operator recovery required.');
    }
    return {'recordCount':count,'pendingCount':pending,'documentPendingCount':documentsPending,'restorePendingCount':restoresPending,'semanticHash':sha256.convert(utf8.encode(jsonEncode(normalized))).toString()};
  }

  static String? _mediaRelative(String value) {
    if(value.startsWith('http:') || value.startsWith('https:') || value.startsWith('data:')) return null;
    var clean=value;
    if(value.startsWith('file:')) {
      final uri=Uri.tryParse(value);
      if(uri==null || uri.scheme!='file') throw StateError('Invalid local file reference.');
      clean=uri.toFilePath(windows:Platform.isWindows);
    }
    clean=clean.replaceAll(r'\','/');
    final index=clean.toLowerCase().indexOf('localfiles/');
    if(index<0 || index>0 && clean[index-1]!='/') return null;
    final relative=clean.substring(index);
    final parts=relative.split('/');
    if(parts.any((p)=>p.isEmpty || p=='.' || p=='..' || p.contains(':'))) throw StateError('Unsafe local media reference.');
    return relative;
  }
}
