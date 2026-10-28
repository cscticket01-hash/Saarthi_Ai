class WindowsDiskStorage{
 WindowsDiskStorage({Future<Map<String,int>> Function(String)? probe,DateTime Function()? clock,bool? supported});
 static const freshness=Duration(minutes:5);
 Future<Map<String,dynamic>> measure(String applicationPath)async=>{'status':'Unknown','reason':'Device storage is unavailable in demo preview'};
}
