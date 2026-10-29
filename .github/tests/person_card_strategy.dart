import '../../lib/windows_school_identity.dart';
import '../../lib/windows_person_card_sync.dart';
Future<void> prepareIdentities(String school) => SchoolPersonIdentity.preparePendingCreates(school);
Future<void> publish(String school, String collection, String id,
    Future<void> Function(Map<String,Set<String>>) prepare,
    Future<void> Function() pushParents,
    Future<void> Function(Set<String>) sendCards,
    String Function(String,String,Map<String,dynamic>) cardId) async {
  await WindowsPersonCardSync.run(school,prepare:prepare,pushParents:pushParents,sendCards:sendCards,cardId:cardId);
}
