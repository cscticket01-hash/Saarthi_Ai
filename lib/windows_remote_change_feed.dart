import 'dart:async';

/// Notification reader only: never uploads, acknowledges, or edits a queue.
class WindowsRemoteChangeFeed {
  WindowsRemoteChangeFeed({required this.read, required this.onHint,
    required this.allowedCollections, this.onError});
  final Future<Map<String,dynamic>> Function(String school, String? cursor) read;
  final void Function(Set<String>) onHint;
  final Set<String> allowedCollections;
  final void Function(Object)? onError;
  Timer? _timer;
  String? _scope, _school, _cursor;
  int _generation=0, _failures=0;
  void start(String scope,String school) {
    if(_scope==scope)return;
    stop();_scope=scope;_school=school;
    _poll(_generation);
  }
  void stop(){_generation++;_timer?.cancel();_timer=null;_scope=null;_school=null;_cursor=null;_failures=0;}
  Future<void> _poll(int generation) async {
    if(generation!=_generation||_school==null)return;
    var delay=const Duration(milliseconds:250);
    try {
      final out=await read(_school!,_cursor);
      if(generation!=_generation)return;
      final names=out['collections'],cursor=out['cursor'];
      if(out['success']!=true||out['schoolId']!=_school||out['changeFeedVersion']!=1||
          out['reset'] is! bool||cursor is! String||cursor.length>80||
          !RegExp(r'^(?:empty|[a-f0-9-]{36}):[0-9]{1,15}$').hasMatch(cursor)||
          names is! List||names.length>allowedCollections.length||
          names.any((c)=>c is! String||!allowedCollections.contains(c))||names.toSet().length!=names.length) {
        throw StateError('Unverified school change notification.');
      }
      _cursor=cursor;_failures=0;
      if(names.isNotEmpty)onHint(names.cast<String>().toSet());
    } catch(error) {
      if(generation!=_generation)return;
      _failures=(_failures+1).clamp(1,6);
      delay=Duration(seconds:(1<<_failures).clamp(2,60));
      onError?.call(error);
    }
    if(generation==_generation)_timer=Timer(delay,()=>_poll(generation));
  }
}
