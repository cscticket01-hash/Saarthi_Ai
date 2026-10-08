import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';

class SchoolMessaging {
  static const _channel=MethodChannel('vidyasaarthi/school_messaging');
  static bool get ready => Firebase.apps.isNotEmpty;
  static Future<bool> configure(Map<String,dynamic>? config, {bool centralSchool=false}) async {
    if(config==null) {
      if (!centralSchool) return false;
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      if (Firebase.app().options.projectId != 'saarthi-ai-df12b')
        throw StateError('Central school messaging identity mismatch');
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
      await FirebaseMessaging.instance.requestPermission(alert:true,badge:true,sound:true);
      return false;
    }
    final project=config['projectId'].toString(),sender=config['messagingSenderId'].toString();
    if(!RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project) ||
        !RegExp(r'^\d+$').hasMatch(sender) ||
        !RegExp('^1:$sender:android:[a-fA-F0-9]+\$').hasMatch(config['appId'].toString())) {
      throw StateError('Ask the school to correct its Android Firebase messaging setup.');
    }
    final restart=await _channel.invokeMethod<bool>('prepare',config) ?? false;
    if(restart) {
      // The new authenticated school session has already been saved. A fresh
      // process prevents the Android Messaging singleton retaining another project.
      await _channel.invokeMethod('restart');
      return true;
    }
    if(Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options:FirebaseOptions(projectId:project,
        apiKey:config['apiKey'].toString(),appId:config['appId'].toString(),messagingSenderId:sender));
    } else if(Firebase.app().options.projectId != project) {
      throw StateError('School messaging identity mismatch');
    }
    await FirebaseMessaging.instance.setAutoInitEnabled(true);
    await FirebaseMessaging.instance.requestPermission(alert:true,badge:true,sound:true);
    await FirebaseMessaging.instance.subscribeToTopic('school_notices');
    return false;
  }
  static Future<void> stop() async {
    if(!ready) return;
    try {
      await FirebaseMessaging.instance.unsubscribeFromTopic('school_notices');
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
      await FirebaseMessaging.instance.deleteToken();
    }catch(_){}
  }
}
