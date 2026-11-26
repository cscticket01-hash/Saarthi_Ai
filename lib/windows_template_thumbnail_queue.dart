import 'dart:typed_data';
import 'windows_runtime_diagnostics.dart';

/// One native thumbnail lane across screens. A tab change invalidates queued
/// work before PDF creation. An already-started native call must finish before
/// another is admitted; do not pretend a timeout cancels a native operation.
/// Never use this queue for issued documents, persistence or full-size print.
class WindowsTemplateThumbnailQueue {
  static Future<void> _lane=Future<void>.value();
  final _cache=<String,Future<Uint8List?>>{};
  int _generation=0;
  int get generation=>_generation;

  void clear(){
    _generation++;
    _cache.clear();
  }

  Future<Uint8List?> request(String key,
    Future<Uint8List?> Function(bool Function() current) render,
    {required bool Function() current}){
    return _cache.putIfAbsent(key,(){
      final generation=_generation;
      bool valid()=>generation==_generation&&current();
      final next=_lane.then<Uint8List?>((_)async{
        if(!valid())return null;
        try{
          final bytes=await render(valid);
          return valid()?bytes:null;
        }catch(error,stack){
          WindowsRuntimeDiagnostics.record('template.thumbnail_failed',error:error,stack:stack);
          return null;
        }
      });
      // Keep the serial lane usable even if a caller's validity check fails.
      _lane=next.then<void>((_){},onError:(Object error,StackTrace stack){
        WindowsRuntimeDiagnostics.record('template.thumbnail_queue_failed',error:error,stack:stack);
      });
      return next;
    });
  }
}
