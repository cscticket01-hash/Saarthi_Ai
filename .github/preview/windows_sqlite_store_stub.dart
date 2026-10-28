import 'dart:io';
class WindowsSqliteStore{
 static const databaseName='preview-never-written.sqlite';
 static Future<WindowsSqliteStore> open(String path)async=>throw UnsupportedError('Native storage is unavailable in theme preview');
 Future<Map<String,dynamic>> readRoot(String profile,{Set<String>? collections,Map<String,List<String>>? recordScope})async=>throw UnsupportedError('Preview storage');
 Future<Map<String,dynamic>?> readDocument(String profile,String collection,String id)async=>null;
 Future<Map<String,Map<String,dynamic>>> readCollection(String profile,String collection)async=>{};
 Future<void> writeRoot(Map<String,dynamic> root,{bool failBeforeCommit=false})async=>throw UnsupportedError('Preview storage');
 Future<Map<String,dynamic>> inventory()async=>{};
 Future<Map<String,dynamic>> readAllRoot()async=>{};
 Future<void> verify()async{}
 Future<Map<String,dynamic>> migrationProof()async=>{};
 Future<void> verifiedMigration(Map<String,dynamic> proof)async{}
 Future<void> snapshot(String target)async=>throw UnsupportedError('Preview storage');
 Future<void> close()async{}
}
class WindowsSqliteMigration{
 static Future<void> rollback(Directory directory,{required bool approved})async=>throw UnsupportedError('Preview storage');
 static Future<Map<String,dynamic>> migrate(Directory directory,{required bool approved,Future<void> Function(String stage)? interruption})async=>throw UnsupportedError('Preview storage');
}
