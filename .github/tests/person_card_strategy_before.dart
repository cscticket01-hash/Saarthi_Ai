import '../../lib/windows_local_firestore.dart';
Future<void> prepareIdentities(String school) async {}
Future<void> publish(String school, String collection, String id,
    Future<void> Function(Map<String,Set<String>>) prepare,
    Future<void> Function() pushParents,
    Future<void> Function(Set<String>) sendCards,
    String Function(String,String,Map<String,dynamic>) cardId) async {
  await prepare({collection=='students_directory'?'studentId':'teacherId':{id}});
  await pushParents();
  final person=(await FirebaseFirestore.instance.collection(collection).doc(id).get()).data()!;
  await sendCards({cardId(collection,id,person)});
}
