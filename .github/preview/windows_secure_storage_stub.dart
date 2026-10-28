// Preview-only replacement in a generated build tree. Never reads browser or OS credentials.
class WindowsSecureStorage{
 const WindowsSecureStorage();
 static final Map<String,String> _memory={};
 static bool? forceCrossProcessLock;
 static bool sharingViolation(Object error)=>false;
 static Future<T> run<T>(Future<T> Function() action)=>action();
 Future<String?> read({required String key})async=>_memory[key];
 Future<void> write({required String key,required String? value})async{if(value==null){_memory.remove(key);}else{_memory[key]=value;}}
 Future<void> delete({required String key})async{_memory.remove(key);}
 Future<Map<String,String>> readAll()async=>Map.of(_memory);
 Future<void> deleteAll()async{_memory.clear();}
}
