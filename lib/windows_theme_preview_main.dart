// Built ONLY as a separate, network-isolated browser preview, never as the portal.
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js;
import 'package:flutter/material.dart';
import 'main_dashboard_screen_windows.dart' as screens;
import 'windows_appearance.dart';
import 'windows_local_firestore.dart';
import 'windows_local_auth.dart' as auth;
import 'windows_html_shim.dart' as shim;
import 'windows_theme_preview_catalog.dart';
import 'windows_staff_payroll.dart';
import 'windows_other_staff.dart';
import 'windows_document_templates.dart';
import 'windows_salary_history.dart';
import 'windows_exam_history_screen.dart';
import 'windows_support_history.dart';
import 'windows_device_management.dart';
import 'windows_recycle_bin.dart';
import 'windows_sync_control_center.dart';

final previewSemanticsHandles=<Object>[];
Future<void> main() async {
 WidgetsFlutterBinding.ensureInitialized();
 previewSemanticsHandles.add(WidgetsBinding.instance.ensureSemantics());
 const preview=bool.fromEnvironment('SAARTHI_THEME_PREVIEW');
 if(!preview)throw StateError('This entry point requires the isolated preview build');
 final db=FirebaseFirestore.instance;
 await db.switchProfile('theme-preview',identity:{'schoolId':'Theme Preview','schoolSyncId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'});
 auth.FirebaseAuth.instance.useManagedIdentity('demo@preview.invalid');
 shim.window.localStorage['saarthi_portal_role_v1']='admin';
 shim.window.localStorage['saarthi_portal_expiry_v1']='${DateTime.now().add(const Duration(days:1)).millisecondsSinceEpoch}';
 await db.collection('school_config').doc('school_profile_cache').set({'schoolName':'Demo Public School','principalName':'Demo Principal','address':'Demo address, India'});
 for(var i=1;i<=5;i++)await db.collection('students_directory').doc('preview-student-$i').set({'name':'Demo Student $i','class':'Class $i','rollNo':i,'parentName':'Demo Parent','contact':'0000000000','phone':'0000000000','gender':i.isEven?'Female':'Male','dob':'2015-01-01','admissionNo':'DEMO-00$i','address':'Demo address, India','uid':'DEMO00$i'});
 await db.collection('teachers_directory').doc('preview-teacher').set({'name':'Demo Teacher','teacherId':'DEMO-T1','subject':'Mathematics','status':'Active','phone':'0000000000','fatherName':'Demo Parent','dob':'1990-01-01','address':'Demo address, India'});
 await db.collection('teacher_salary').doc(StaffPayroll.rowId('teacher:preview-teacher',StaffPayroll.monthKey(DateTime.now()))).set({'name':'Demo Teacher','teacherId':'DEMO-T1','staffId':'teacher:preview-teacher','role':'Teacher','month':StaffPayroll.monthKey(DateTime.now()),'amount':15000,'netPaise':1500000,'paidPaise':500000,'status':'Partial','payments':[{'amountPaise':500000,'date':'2026-10-01T10:30:00','reference':'DEMO'}]});
 await db.collection('school_notices').doc('preview-notice').set({'title':'Demo school notice','body':'A sample notice for colour preview.','date':'2026-10-01','timestamp':DateTime.now().millisecondsSinceEpoch});
 await db.collection('school_expenses').doc('preview-expense').set({'title':'Demo supplies','amount':1250,'category':'Stationery','date':'2026-10-01','timestamp':DateTime.now().millisecondsSinceEpoch});
 runApp(const WindowsPreviewApp());
}
class WindowsPreviewApp extends StatefulWidget{const WindowsPreviewApp({super.key});@override State<WindowsPreviewApp> createState()=>_PreviewState();}
class _PreviewState extends State<WindowsPreviewApp>{
 final navigator=GlobalKey<NavigatorState>();String current='dashboard';int lastNavigation=-1;
 Map<String,WidgetBuilder> get pages=>{
  'dashboard':(_)=>const screens.AdminDashboardScreen(),'analytics':(_)=>const screens.AdminAnalyticsScreen(),
  'students':(_)=>const screens.AllStudentsListScreen(),'add-student':(_)=>const screens.AllStudentsListScreen(),
  'teachers':(_)=>const SchoolStaffDirectory(teachers:screens.TeachersDirectoryScreen(embedded:true)),
  'add-teacher':(_)=>const screens.AddTeacherScreen(),'fees':(_)=>const screens.FeesCollectionScreen(),
  'fee-settings':(_)=>const screens.FeeCollectionSettingsScreen(),'salary':(_)=>const StaffSalaryScreen(),
  'expenses':(_)=>const screens.WindowsSchoolExpensesScreen(),'attendance':(_)=>const screens.WindowsAttendanceScreen(),
  'exams':(_)=>const screens.ExamCenterScreen(),'templates':(_)=>const SchoolDocumentTemplatesScreen(),
  'school':(_)=>const screens.SchoolSettingsScreen(),'admin':(_)=>const screens.AdminSettingsScreen(),
  'settings':(_)=>const screens.SettingsScreen(),'advanced':(_)=>const screens.AdvancedSettingsScreen(),
  'fee-history':(_)=>const screens.FeeTransactionHistoryScreen(),'exam-history':(_)=>const WindowsExamHistoryScreen(),
  'support':(_)=>const WindowsComplaintHistory(),'devices':(_)=>const WindowsDeviceManagement(),'recycle':(_)=>const WindowsRecycleBin(),'sync':(_)=>const WindowsSyncControlCenter(),
  'salary-history':(_)=>StaffSalaryHistoryScreen(profile:FirebaseFirestore.instance.activeProfileId),
 };
 @override void initState(){super.initState();html.window.onMessage.listen((event){
  if(!identical(js.getProperty(event,'source'),js.getProperty(html.window,'parent'))||event.origin!=html.window.location.origin||event.data is! String)return;
  try{final data=jsonDecode(event.data as String);if(data is! Map||data['type']!='vidya-preview-theme')return;
   if(data['mode']!='dark'&&data['mode']!='light')return;
   if(data['page'] is! String||!windowsThemePreviewPages.containsKey(data['page'])||data['navigation'] is! int)return;
   if(!['red','green','blue'].every((k)=>data[k] is int&&data[k]>=0&&data[k]<=255))return;
   WindowsAppearance.applyBrand({'schemaVersion':1,'red':data['red'],'green':data['green'],'blue':data['blue'],'revision':'preview'},persist:false);
   WindowsAppearance.mode.value=data['mode']=='light'?ThemeMode.light:ThemeMode.dark;
   final page=data['page'];if(page is String&&windowsThemePreviewPages.containsKey(page)&&data['navigation']!=lastNavigation){lastNavigation=data['navigation'] is int?data['navigation']:0;current=page;navigator.currentState?.pushNamedAndRemoveUntil('/$page',(_)=>false);}
   WidgetsBinding.instance.addPostFrameCallback((_){html.window.parent?.postMessage(jsonEncode({'type':'vidya-preview-applied','page':current,'mode':WindowsAppearance.mode.value==ThemeMode.light?'light':'dark','red':WindowsAppearance.brandData['red'],'green':WindowsAppearance.brandData['green'],'blue':WindowsAppearance.brandData['blue'],'navigation':lastNavigation}),html.window.location.origin);});
  }catch(_){}
 });WidgetsBinding.instance.addPostFrameCallback((_){html.window.parent?.postMessage(jsonEncode({'type':'vidya-preview-ready'}),html.window.location.origin);});}
 @override Widget build(BuildContext context)=>ValueListenableBuilder<Color>(valueListenable:WindowsAppearance.brand,builder:(_,__,___)=>ValueListenableBuilder<ThemeMode>(valueListenable:WindowsAppearance.mode,builder:(_,mode,___)=>MaterialApp(navigatorKey:navigator,debugShowCheckedModeBanner:false,theme:WindowsAppearance.theme(Brightness.light),darkTheme:WindowsAppearance.theme(Brightness.dark),themeMode:mode,home:const screens.AdminDashboardScreen(),routes:{for(final e in pages.entries)'/${e.key}':e.value},builder:(c,child)=>Column(children:[Material(color:Theme.of(c).colorScheme.primaryContainer,child:Padding(padding:const EdgeInsets.all(6),child:Row(children:[const Icon(Icons.science_outlined,size:18),const SizedBox(width:8),const Expanded(child:Text('DEMO PREVIEW • Actual Windows screens • No real school data • Native storage, cloud and device actions are unavailable',style:TextStyle(fontSize:12))),TextButton(onPressed:()=>navigator.currentState?.pushNamedAndRemoveUntil('/dashboard',(_)=>false),child:const Text('Dashboard'))]))),Expanded(child:child??const SizedBox())]))));
}
