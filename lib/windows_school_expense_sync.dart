import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';
import 'windows_sync_engine.dart';

/// School expenses use the same durable record-level queue as fees and salary.
/// Local commit is the only success boundary here; never claim Google/Drive ACK.
class WindowsSchoolExpenseSync {
  static Future<bool> get enabled async =>
      (await CentralSchoolCloud.saved())['managed'] == true;

  /// Pure validation/projection used in the immediate-save and recovery paths.
  /// No second cloud operation is created by this projection.
  static Map<String,dynamic> recordForSchool(
    String school, Map<String,dynamic> intent,
  ) {
    final id=intent['expenseId']?.toString().trim() ?? '';
    final amount=intent['amount'];
    if (school.trim().isEmpty || id.isEmpty ||
        intent['action'] != 'save_school_expense' ||
        intent['title']?.toString().trim().isEmpty != false ||
        amount is! num || !amount.isFinite || amount <= 0 ||
        intent['timestamp'] is! num) {
      throw StateError('Expense intent invalid. Nothing was queued.');
    }
    return <String,dynamic>{
      'expenseId':id,
      'schoolId':school,
      'title':intent['title'].toString().trim(),
      'category':intent['category']?.toString() ?? 'General',
      'amount':amount,
      'paidTo':intent['paidTo']?.toString() ?? '',
      'note':intent['note']?.toString() ?? '',
      'dateText':intent['dateText']?.toString() ?? '',
      'timestamp':(intent['timestamp'] as num).toInt(),
    };
  }

  static Future<Map<String,dynamic>> save(
    String profile,
    String school,
    Map<String,dynamic> intent,
  ) async {
    final db = FirebaseFirestore.instance;
    void verify() {
      if (db.activeProfileId != profile ||
          db.activeProfileIdentity['schoolSyncId'] != school ||
          school.isEmpty) {
        throw StateError('School changed. Reopen School Expenses.');
      }
    }
    verify();
    final record=recordForSchool(school,intent);
    final id=record['expenseId'] as String;
    final doc=db.collection('school_expenses').doc(id);
    final existing=(await doc.get()).data();
    verify();
    if(existing!=null) {
      // Retrying an uncertain result is allowed only for the exact same
      // financial intent. Never overwrite or duplicate a different expense.
      for(final field in record.keys) {
        if(existing[field]!=record[field]) {
          throw StateError('Expense ID already holds different data. Original retained.');
        }
      }
      WindowsSyncEngine.instance.scheduleSoon(delay: const Duration(milliseconds: 100));
      return {'success':true,'expenseId':id,'cloudSyncPending':true};
    }
    await doc.set(record);
    verify();
    // Schedule a real delta flush; do not create a second Google/Sheet write
    // from this screen. The standard sync owner handles ACKs and retries.
    WindowsSyncEngine.instance.scheduleSoon(delay: const Duration(milliseconds: 100));
    return {'success':true,'expenseId':id,'cloudSyncPending':true};
  }
}
