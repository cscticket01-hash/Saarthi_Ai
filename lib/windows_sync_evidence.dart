import 'package:flutter/foundation.dart';

/// Network activity is scoped to the actual school and excludes metadata polls.
class WindowsSyncEvidence {
  static final active=ValueNotifier<Map<String,int>>({});
  static final uploads = ValueNotifier<Map<Object, ({String school, int offset, int total})>>({});
  static void reportUpload(Object key, String school, int offset, int total) {
    uploads.value = {...uploads.value, key: (school: school, offset: offset, total: total)};
  }

  static void endUpload(Object key) {
    if (uploads.value.containsKey(key)) {
      uploads.value = {...uploads.value}..remove(key);
    }
  }

  static ({int offset, int total})? measuredUpload(String school) {
    final matches = uploads.value.values.where((upload) => upload.school == school);
    if (matches.length != 1) return null;
    final upload = matches.single;
    return (offset: upload.offset, total: upload.total);
  }

  static bool dataAction(String action)=>action.startsWith('managed/file/')||
      {'managed/records','managed/records/batch','managed/document/stage/resumable',
       'managed/record/media/stage/resumable'}.contains(action);
  static void enter(String school,String lane){final key='$school:$lane';active.value={...active.value,key:(active.value[key]??0)+1};}
  static void leave(String school,String lane){final key='$school:$lane',value=(active.value[key]??0)-1;final next={...active.value}..remove(key);if(value>0)next[key]=value;active.value=next;}
  static Set<String> lanes(String school)=>{for(final lane in ['local','cloud','drive']) if((active.value['$school:$lane']??0)>0)lane};
}

const repairHistoryAge=Duration(hours:24);
bool recentRepairEvent(Map event,int now){
  final at=event['atUtc'] is String?DateTime.tryParse(event['atUtc'] as String)?.millisecondsSinceEpoch:event['at']??event['lastAt'];
  return at is int && at<=now && now-at<repairHistoryAge.inMilliseconds;
}
List<Map<String,dynamic>> recentRepairHistory(Iterable<Map<String,dynamic>> events,int now)=>events.where((e)=>recentRepairEvent(e,now)).take(100).toList();

/// Last timing changes only for a completed, data-bearing verified cycle.
class VerifiedSyncTiming {
  int sequence=0;
  int? lastMicros, completedAt;
  void verified()=>sequence++;
  bool complete({required int startSequence,required int micros,required int now,required bool idle}){
    if(!idle||sequence<=startSequence||micros<0||now<0)return false;
    lastMicros=micros;completedAt=now;return true;
  }
  void clear(){sequence=0;lastMicros=null;completedAt=null;}
  Map<String,dynamic> snapshot(String school)=>{'schoolId':school,'micros':lastMicros,'completedAt':completedAt};
  void restore(Map? raw,String school){clear();if(raw?['schoolId']==school&&raw?['micros'] is int&&raw?['completedAt'] is int&&raw!['micros']>=0&&raw['completedAt']>=0){lastMicros=raw['micros'];completedAt=raw['completedAt'];}}
}
