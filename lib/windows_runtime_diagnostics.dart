import 'dart:convert';
import 'dart:io';

/// Bounded local diagnostics. Do not store exception messages, school data,
/// arbitrary stack paths, credentials or URLs. Never upload automatically.
class WindowsRuntimeDiagnostics {
  WindowsRuntimeDiagnostics._();
  static const maxBytes=64*1024;
  static const version=String.fromEnvironment('APP_VERSION',defaultValue:'1.0.0');
  static final _last=<String,DateTime>{};

  static File? get _file {
    final base=Platform.environment['APPDATA']??Platform.environment['LOCALAPPDATA'];
    if(base==null||base.trim().isEmpty)return null;
    return File([base,'VidyaSaarthi','runtime_diagnostics.jsonl'].join(Platform.pathSeparator));
  }

  static Map<String,dynamic> event(String stage,{Object? error,StackTrace? stack}) {
    final safeStage=RegExp(r'^[a-z0-9_.-]{1,80}$').hasMatch(stage)?stage:'unknown';
    final frames=RegExp(r'package:saarthi_ai/([a-zA-Z0-9_/.]+\.dart):([0-9]+):([0-9]+)')
      .allMatches(stack?.toString()??'').take(8)
      .map((m)=>[m[1],m[2],m[3]].join(':')).toList();
    return {'at':DateTime.now().toUtc().toIso8601String(),'version':version,
      'stage':safeStage,if(error!=null)'errorType':error.runtimeType.toString(),
      if(frames.isNotEmpty)'frames':frames};
  }

  static void record(String stage,{Object? error,StackTrace? stack}) {
    try{
      final row=event(stage,error:error,stack:stack);
      final key=[row['stage'],row['errorType']??''].join(':');
      final now=DateTime.now(),last=_last[key];
      if(error!=null&&last!=null&&now.difference(last)<const Duration(seconds:30))return;
      if(_last.length>=100)_last.clear();
      _last[key]=now;
      final file=_file;
      if(file==null)return;
      file.parent.createSync(recursive:true);
      final line=jsonEncode(row)+'\n';
      if(file.existsSync()&&file.lengthSync()+utf8.encode(line).length>maxBytes){
        final previous=File(file.path+'.previous');
        if(previous.existsSync())previous.deleteSync();
        file.renameSync(previous.path);
      }
      file.writeAsStringSync(line,mode:FileMode.append,flush:true);
    }catch(_){/* Logging must never cause an application failure. */}
  }

  /// Best-effort tasks only, never commits, access checks or cloud ACKs.
  static Future<void> background(String stage,Future<void> Function() work,
      {void Function(Object,StackTrace)? onFailure})async{
    try{await work();}
    catch(error,stack){
      record(stage,error:error,stack:stack);
      onFailure?.call(error,stack);
    }
  }
}
