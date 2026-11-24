import 'windows_payment_confirmation.dart';
import 'main_dashboard_screen_windows.dart' show WindowsSectionLocks;
import 'windows_appearance.dart';
import 'windows_other_staff.dart';
import 'windows_school_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';
import 'windows_document_templates.dart';
import 'windows_salary_history.dart';
import 'windows_salary_payment_correction.dart';
import 'windows_local_settings.dart';
import 'windows_receipt_print_dialog.dart';
import 'windows_save_pdf.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';
import 'windows_local_firestore.dart';
import 'windows_sheet_recovery.dart' show sheetRecoveryCacheKey;
import 'live_sync_protocol.dart' show isDriveRecoveryRevision;

/// Integer paise throughout calculations; rupee fields remain compatible with
/// the school-owned mobile backend's existing teacher_salary response.
class StaffPayroll {
  static Future<void> _tail = Future<void>.value();
  static String monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
  static int money(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch(text)) {
      throw const FormatException('Enter a positive amount with at most two decimal places.');
    }
    final parts = text.split('.');
    return int.parse(parts[0]) * 100 + (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }
  static String format(int paise) => (paise / 100).toStringAsFixed(2);
  static int net({required int basic, int allowance = 0, int bonus = 0, int overtime = 0, int deduction = 0}) {
    if ([basic, allowance, bonus, overtime, deduction].any((v) => v < 0)) throw ArgumentError('Salary amounts cannot be negative.');
    final total = basic + allowance + bonus + overtime - deduction;
    if (total < 0) throw ArgumentError('Deductions cannot exceed earnings.');
    return total;
  }
  static String rowId(String staffId, String month) {
    if (staffId.trim().isEmpty || !RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) throw ArgumentError('Staff and salary month are required.');
    return sha256.convert(utf8.encode(jsonEncode([staffId, month]))).toString();
  }
  static void _sameSchool(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Reopen the salary page.');
  }
  static Future<void> _durable(String profile) async {
    _sameSchool(profile);
    await FirebaseFirestore.instance.ensureDurableSchoolRecords();
    _sameSchool(profile);
    if(!await FirebaseFirestore.instance.localPersistenceEnabled())throw StateError('Durable school storage is required before recording salary changes.');
    _sameSchool(profile);
  }
  static Future<void> requireAdmin(String profile, String? password) async {
    _sameSchool(profile);
    if (password == null || !await WindowsSectionLocks.verify(sectionKey: 'admin_section', password: password)) {
      throw StateError('Admin Section password verification required. Configure it in Password Management.');
    }
    _sameSchool(profile);
  }
  static Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
  /// Display grouping only: retain the stored role and salary identifiers.
  static String displayCategory(Map<String, dynamic> person) =>
      person['role'] == 'Teacher'
          ? 'Teacher'
          : OtherStaffDirectory.categoryFor(person);

  static Future<List<Map<String, dynamic>>> staff(String profile) async {
    _sameSchool(profile);
    final teachers = await FirebaseFirestore.instance.collection('teachers_directory').get();
    final extra = await OtherStaffDirectory.load(profile);
    _sameSchool(profile);
    return [
      for (final d in teachers.docs.where((d)=>d.data()['active']!=false&&d.data()['inactive']!=true&&d.data()['_syncDeleted']!=true)) {
        'id': 'teacher:${d.id}',
        'teacherId': (d.data()['teacherId']?.toString().trim().isNotEmpty ?? false) ? d.data()['teacherId'] : d.id,
        'employeeId': d.data()['teacherId'] ?? d.id,
        'name': d.data()['name'] ?? d.data()['teacherName'] ?? d.id,
        'role': 'Teacher', 'designation': d.data()['designation'] ?? 'Teacher',
        'mobileStableId': d.data()['mobileStableId'],
      },
      for (final d in extra.where((p)=>p['active']!=false)) d,
    ];
  }
  static Future<void> addStaff(String profile, String name, String role, String designation) => _serial(() async {
    _sameSchool(profile);
    if (name.trim().isEmpty || name.trim().length > 120 || designation.length > 120) throw ArgumentError('Enter a staff name (up to 120 characters).');
    if (!OtherStaffDirectory.roles.contains(role) &&
        !OtherStaffDirectory.legacyOtherRoles.contains(role)) {
      throw ArgumentError('Select a staff category. Add teachers in the Teachers section.');
    }
    if (OtherStaffDirectory.categoryFor({'role': role}) == 'Other staff' &&
        designation.trim().isEmpty) {
      throw ArgumentError('Enter a designation for Other Staff.');
    }
    final ref = FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory');
    final previous = await ref.get();
    _sameSchool(profile);
    final people = List<dynamic>.from(previous.data()?['staff'] as List? ?? []);
    final generation = SchoolPersonIdentity.newGeneration();
    people.add({
      'id': 'staff:$generation',
      'mobileStableId': generation,
      'name': name.trim(),
      'role': role,
      'designation': designation.trim(),
    });
    final batch = FirebaseFirestore.instance.batch();
    batch.requireUnchanged(ref, previous.data());
    batch.set(ref, {'staff': people}, SetOptions(merge: true));
    await batch.commit();
  });
  static int paid(Map<String, dynamic> row) => (row['paidPaise'] as num?)?.toInt() ??
      (row['status']?.toString().toLowerCase() == 'paid' ? total(row) : 0);
  static int total(Map<String, dynamic> row) => (row['netPaise'] as num?)?.toInt() ?? ((row['amount'] as num? ?? 0) * 100).round();
  static Future<Set<String>> verifiedAttendanceDays(String profile,Map<String,dynamic> person,String month) async{
    _sameSchool(profile);
    final stable=person['mobileStableId']?.toString()??'';
    if(stable.isEmpty)return {};
    final snapshot=await FirebaseFirestore.instance.collection('attendance_records').where('personId',isEqualTo:stable).get();
    _sameSchool(profile);
    return {for(final doc in snapshot.docs)
      if(doc.data()['role']=='teacher'&&doc.data()['personId']==stable&&doc.data()['checkIn'] is num&&(doc.data()['checkIn'] as num)>0&&
        (doc.data()['date']?.toString()??'').startsWith('$month-'))
      doc.data()['date'].toString()};
  }
  static Set<String> schoolWorkingDays(String month,Iterable<Map<String,dynamic>> calendar,List<dynamic> closedWeekdays){
    rowId('attendance-calendar',month);
    if(closedWeekdays.any((v)=>v is! int||v<0||v>6))throw StateError('School calendar settings require review.');
    final start=DateTime.parse('$month-01');
    final end=DateTime(start.year,start.month+1,1);
    final overrides=<String,bool>{};
    for(final r in calendar){
      final key=(r['date']??r['id'])?.toString()??'';
      if(!key.startsWith('$month-')||r['_syncDeleted']==true)continue;
      final day=DateTime.tryParse(key);
      if(day==null||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key)||day.toIso8601String().substring(0,10)!=key||r['isOpen'] is! bool)throw StateError('Invalid school calendar entry.');
      final open=r['isOpen'] as bool;
      if(overrides.containsKey(key)&&overrides[key]!=open)throw StateError('Conflicting school calendar entries.');
      overrides[key]=open;
    }
    final result=<String>{};
    for(var d=start;d.isBefore(end);d=DateTime(d.year,d.month,d.day+1)){
      final key=d.toIso8601String().substring(0,10);
      if(overrides[key]??!closedWeekdays.contains(d.weekday%7))result.add(key);
    }
    return result;
  }
  static Future<Set<String>> loadWorkingDays(String profile,String month)async{
    _sameSchool(profile);
    final db=FirebaseFirestore.instance;
    final config=(await db.collection('school_settings').doc('calendar').get()).data();
    final rows=await db.collection('school_calendar').get();
    _sameSchool(profile);
    final closed=config?['closedWeekdays']??[0];
    if(closed is! List)throw StateError('School calendar settings require review.');
    return schoolWorkingDays(month,[for(final r in rows.docs){...r.data(),'id':r.id}],closed);
  }
  static int proratedDailyRate(int basicPaise,int workingDays){
    if(basicPaise<0||workingDays<=0)throw ArgumentError('A valid basic salary and school working days are required.');
    return (basicPaise+workingDays~/2)~/workingDays;
  }
  static Set<String> validatedUnpaidDays(String month,String raw,Set<String> present,DateTime now,{Set<String>? workingDays}){
    final dates=raw.split(',').map((v)=>v.trim()).where((v)=>v.isNotEmpty).toList();
    if(dates.toSet().length!=dates.length)throw FormatException('Duplicate unpaid dates.');
    final today=DateTime(now.year,now.month,now.day);
    for(final d in dates){
      final parsed=DateTime.tryParse(d);
      if(!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)||!d.startsWith('$month-')||parsed==null||
        parsed.toIso8601String().substring(0,10)!=d||!parsed.isBefore(today)||present.contains(d)||workingDays!=null&&!workingDays.contains(d)){
        throw FormatException('Invalid, closed, future/current or recorded-present unpaid date: $d');
      }
    }
    return dates.toSet();
  }
  /// Only normalize fields that are already provable from this row. Never
  /// manufacture a dated transaction or infer an ambiguous partial amount.
  static Map<String,dynamic>? legacyProposal(Map<String,dynamic> row){
    if(row['_syncDeleted']==true||row['month'] is! String||!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(row['month'] as String))return null;
    if(row['netPaise'] is int&&row['paidPaise'] is int&&row['balancePaise']==null){
      final net=row['netPaise'] as int,paid=row['paidPaise'] as int;
      if(net<0||paid<0||paid>net||row['status']!=(paid==net?'Paid':paid==0?'Pending':'Part paid'))return null;
      return {'balancePaise':net-paid};
    }
    if(row['netPaise']!=null||row['balancePaise']!=null||row['amount'] is! num||
      (row['payments'] as List? ?? []).isNotEmpty||(row['paymentCorrections'] as List? ?? []).isNotEmpty||
      ['basicPaise','allowancePaise','bonusPaise','overtimePaise','deductionPaise'].any(row.containsKey))return null;
    final amount=(row['amount'] as num).toDouble(),scaled=amount*100;
    if(!scaled.isFinite||scaled<0||scaled>99999999999||(scaled-scaled.round()).abs()>0.00001)return null;
    final net=scaled.round(),status=(row['status']?.toString()??'').toLowerCase();
    if(status!='paid'&&status!='pending')return null;
    final paid=status=='paid'?net:0;
    if(row['paidPaise']!=null&&row['paidPaise']!=paid)return null;
    return {'netPaise':net,'paidPaise':paid,'balancePaise':net-paid,'status':paid==net?'Paid':'Pending'};
  }
  static Future<List<Map<String,dynamic>>> legacyReview(String profile)async{
    _sameSchool(profile);
    final data=await FirebaseFirestore.instance.collection('teacher_salary').get();
    _sameSchool(profile);
    final rows=[for(final d in data.docs){...d.data(),'id':d.id}];
    String owner(Map<String,dynamic> r){
      final teacher=(r['teacherId']?.toString()??'').trim();
      return teacher.isNotEmpty?'teacher:$teacher':(r['staffId']?.toString()??'');
    }
    final counts=<String,int>{};
    for(final row in rows){
      if(owner(row).isEmpty||row['month']==null)continue;
      final key=jsonEncode([owner(row),row['month']]);counts[key]=(counts[key]??0)+1;
    }
    final review=<Map<String,dynamic>>[];
    for(final row in rows){
      final key=jsonEncode([owner(row),row['month']]);
      final duplicate=(counts[key]??0)>1;
      if(!duplicate&&row['netPaise']!=null&&row['balancePaise']!=null)continue;
      Map<String,dynamic>? proposal;
      try{if(!duplicate&&owner(row).isNotEmpty)proposal=legacyProposal(row);}catch(_){}
      review.add({...row,'reviewIssue':duplicate?'Duplicate owner/month; manual reconciliation required':proposal==null?'Ambiguous legacy record; original retained':'Derived fields available for reviewed normalization','canNormalize':proposal!=null});
    }
    return review;
  }
  static Future<void> normalizeLegacy(String profile,String id,{required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    final review=await legacyReview(profile);
    if(!review.any((r)=>r['id']==id&&r['canNormalize']==true))throw StateError('Record is ambiguous or already normalized. Refresh review.');
    final db=FirebaseFirestore.instance,ref=db.collection('teacher_salary').doc(id);
    final row=(await ref.get()).data();
    _sameSchool(profile);
    if(row==null)throw StateError('Legacy record missing.');
    final proposal=legacyProposal(row);
    if(proposal==null)throw StateError('No safe normalization available.');
    await _requireMonthOpen(profile,row['month'] as String);
    if(row['salaryLocked']==true)throw StateError('Reopen the approved salary before normalizing.');
    await requireAdmin(profile,adminPassword);
    final batch=db.batch();
    batch.requireUnchanged(ref,row);
    batch.update(ref,{...proposal,'updatedAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();
  });
  static String monthControlId(String month){
    rowId('month-control',month);
    return 'payroll_month_'+month;
  }
  static Future<bool> monthClosed(String profile,String month) async{
    _sameSchool(profile);
    final value=(await FirebaseFirestore.instance.collection('school_settings').doc(monthControlId(month)).get()).data();
    _sameSchool(profile);
    if(value!=null&&value['month']!=month)throw StateError('Payroll month control identity mismatch.');
    return value?['closed']==true;
  }
  static Future<void> _requireMonthOpen(String profile,String month) async{
    if(await monthClosed(profile,month))throw StateError('Payroll month is closed. Reopen with Admin Password before changing salary or correcting payment.');
  }
  static Future<void> setMonthClosed(String profile,String month,{required bool closed,required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    final db=FirebaseFirestore.instance,ref=db.collection('school_settings').doc(monthControlId(month));
    final old=(await ref.get()).data();
    _sameSchool(profile);
    if(old!=null&&old['month']!=month)throw StateError('Payroll month control identity mismatch.');
    if((old?['closed']==true)==closed)return;
    await WindowsLocalSecurity.initialize();
    await requireAdmin(profile,adminPassword);
    final history=List<dynamic>.from(old?['history'] as List? ?? []);
    history.add({'id':SchoolPersonIdentity.newGeneration(),'closed':closed,'at':DateTime.now().millisecondsSinceEpoch,
      if(WindowsLocalSecurity.configured)'recordedBy':WindowsLocalSecurity.adminId});
    final batch=db.batch();
    batch.requireUnchanged(ref,old);
    batch.set(ref,{'month':month,'closed':closed,'history':history,'updatedAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();
  });
  static String advanceId(String staffId) => 'payroll_advance_'+sha256.convert(utf8.encode(staffId)).toString();
  static int advanceBalance(Iterable<dynamic> events){
    var balance=0;
    final ids=<String>{};
    for(final event in events){
      if(event is! Map||event['id'] is! String||!ids.add(event['id'] as String)||event['amountPaise'] is! int||(event['amountPaise'] as int)<=0)throw StateError('Advance history requires review.');
      final amount=event['amountPaise'] as int;
      if(event['type']=='advance'||event['type']=='loan')balance+=amount;
      else if(event['type']=='repayment')balance-=amount;
      else throw StateError('Unknown advance event.');
      if(balance<0)throw StateError('Advance repayment exceeds the outstanding amount.');
    }
    return balance;
  }
  static Future<Map<String,dynamic>?> advanceLedger(String profile,String staffId) async{
    _sameSchool(profile);
    final row=(await FirebaseFirestore.instance.collection('school_settings').doc(advanceId(staffId)).get()).data();
    _sameSchool(profile);
    if(row!=null&&(row['staffId']!=staffId||row['balancePaise']!=advanceBalance(row['events'] as List? ?? [])))throw StateError('Advance ledger identity or balance requires review.');
    return row;
  }
  static Future<void> recordAdvance(String profile,String staffId,{required String type,required int amount,required String eventId,required String reference,required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    if(amount<=0||eventId.isEmpty||reference.trim().isEmpty||reference.length>500||!['advance','loan','repayment'].contains(type))throw ArgumentError('Enter a valid amount, event and payment reference.');
    final db=FirebaseFirestore.instance,ref=db.collection('school_settings').doc(advanceId(staffId));
    final before=await advanceLedger(profile,staffId);
    final people=await staff(profile);
    if(!people.any((p)=>p['id']==staffId)&&(before==null||type!='repayment'))throw StateError('Active staff required for a new advance or loan.');
    final events=List<dynamic>.from(before?['events'] as List? ?? []);
    final prior=events.where((e)=>e is Map&&e['id']==eventId).toList();
    if(prior.isNotEmpty){
      if(prior.length!=1||prior.single['type']!=type||prior.single['amountPaise']!=amount||prior.single['reference']!=reference.trim())throw StateError('Advance event ID conflict.');
      return;
    }
    await WindowsLocalSecurity.initialize();
    await requireAdmin(profile,adminPassword);
    events.add({'id':eventId,'type':type,'amountPaise':amount,'reference':reference.trim(),'recordedAt':DateTime.now().millisecondsSinceEpoch,
      if(WindowsLocalSecurity.configured)'recordedBy':WindowsLocalSecurity.adminId});
    final balance=advanceBalance(events);
    final batch=db.batch();
    batch.requireUnchanged(ref,before);
    batch.set(ref,{'staffId':staffId,'events':events,'balancePaise':balance,'updatedAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();
  });
  static String structureId(String staffId) => 'payroll_salary_structure_${sha256.convert(utf8.encode(staffId))}';
  static Future<Map<String,dynamic>?> structure(String profile,String staffId) async {
    _sameSchool(profile);
    final row=(await FirebaseFirestore.instance.collection('school_settings').doc(structureId(staffId)).get()).data();
    _sameSchool(profile);
    if(row!=null&&row['staffId']!=staffId)throw StateError('Salary structure identity mismatch.');
    return row;
  }
  static Future<void> saveStructure(String profile,String staffId,{required int basic,required int allowance,required int deduction,required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    net(basic:basic,allowance:allowance,deduction:deduction);
    final people=await staff(profile);
    if(people.where((p)=>p['id']==staffId).length!=1)throw StateError('Active staff not found.');
    final ref=FirebaseFirestore.instance.collection('school_settings').doc(structureId(staffId));
    final old=(await ref.get()).data();
    if(old!=null&&old['staffId']!=staffId)throw StateError('Salary structure identity mismatch.');
    await requireAdmin(profile,adminPassword);
    final batch=FirebaseFirestore.instance.batch();
    batch.requireUnchanged(ref,old);
    batch.set(ref,{'staffId':staffId,'basicPaise':basic,'allowancePaise':allowance,'deductionPaise':deduction,'updatedAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();
  });
  static bool _matchesEmployee(Map<String,dynamic> row,Map<String,dynamic> person) =>
      row['staffId']==person['id'] || ((row['staffId']?.toString()??'').isEmpty &&
      (person['teacherId']?.toString()??'').isNotEmpty && row['teacherId']==person['teacherId']);
  static Future<Map<String,int>> generateMonth(String profile,String month,{required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    await _requireMonthOpen(profile,month);
    final people=await staff(profile);
    final db=FirebaseFirestore.instance;
    final existing=(await db.collection('teacher_salary').where('month',isEqualTo:month).get()).docs.map((d)=>d.data()).toList();
    final batch=db.batch();
    int created=0,skipped=0,missing=0;
    final now=DateTime.now().millisecondsSinceEpoch;
    for(final p in people){
      _sameSchool(profile);
      final staffId=p['id'].toString();
      if(existing.any((r)=>_matchesEmployee(r,p))){skipped++;continue;}
      final template=await structure(profile,staffId);
      if(template==null){missing++;continue;}
      final basic=template['basicPaise'],allowance=template['allowancePaise'],deduction=template['deductionPaise'];
      if(basic is! int||allowance is! int||deduction is! int)throw StateError('Invalid saved salary structure for ${p['name']}.');
      final amount=net(basic:basic,allowance:allowance,deduction:deduction);
      final id=rowId(staffId,month);
      final ref=db.collection('teacher_salary').doc(id);
      if((await ref.get()).data()!=null){skipped++;continue;}
      _sameSchool(profile);
      batch.requireUnchanged(ref,null);
      batch.set(ref,{'id':id,'staffId':staffId,'teacherId':p['teacherId']??'','employeeId':p['employeeId']??p['teacherId']??'',
       'name':p['name'],'role':p['role'],'designation':p['designation'],'month':month,'basicPaise':basic,
       'allowancePaise':allowance,'bonusPaise':0,'overtimePaise':0,'deductionPaise':deduction,'netPaise':amount,
       'amount':amount/100,'paidPaise':0,'balancePaise':amount,'status':amount==0?'Paid':'Pending','updatedAt':now});
      created++;
    }
    await requireAdmin(profile,adminPassword);
    if(created>0)await batch.commit();
    return {'created':created,'existing':skipped,'missing':missing};
  });
  static Future<Map<String, dynamic>> save(String profile, Map<String, dynamic> person, String month,
      {required int basic, int allowance = 0, int bonus = 0, int overtime = 0, int deduction = 0, String? adminPassword, Map<String,dynamic>? attendanceAdjustment}) => _serial(() async {
    await _durable(profile);
    await _requireMonthOpen(profile,month);
    final people = await staff(profile);
    final current = people.where((s) => s['id'] == person['id']);
    if (current.length != 1) throw StateError('Staff record is no longer available. Reload the page.');
    final employee = current.single;
    if(attendanceAdjustment!=null){
      final dates=attendanceAdjustment['unpaidDates'],rate=attendanceAdjustment['ratePaise'],reason=attendanceAdjustment['reason'];
      if(dates is! List||rate is! int||rate<0||reason is! String||reason.trim().isEmpty)throw StateError('Attendance adjustment requires approved dates, rate and reason.');
      final present=await verifiedAttendanceDays(profile,employee,month);
      final workingDays=await loadWorkingDays(profile,month);
      final checked=validatedUnpaidDays(month,dates.join(','),present,DateTime.now(),workingDays:workingDays);
      if(checked.length*rate>deduction||attendanceAdjustment['amountPaise']!=checked.length*rate)throw StateError('Invalid attendance deduction.');
      await requireAdmin(profile,adminPassword);
    }
    final amount = net(basic: basic, allowance: allowance, bonus: bonus, overtime: overtime, deduction: deduction);
    final id = rowId(employee['id'].toString(), month);
    final ref = FirebaseFirestore.instance.collection('teacher_salary').doc(id);
    final before = (await ref.get()).data();
    final old = before ?? <String, dynamic>{};
    _sameSchool(profile);
    if(before==null){
      final sameMonth=await FirebaseFirestore.instance.collection('teacher_salary').where('month',isEqualTo:month).get();
      _sameSchool(profile);
      if(sameMonth.docs.any((d)=>d.id!=id&&_matchesEmployee(d.data(),employee)))throw StateError('A historical salary row already exists for this staff and month. Review it before creating another.');
    }
    if (before != null) {
      if(old['salaryLocked']==true)throw StateError('Salary is approved and locked. Reopen it with the Admin Password before editing.');
      final same = old['basicPaise']==basic && old['allowancePaise']==allowance && old['bonusPaise']==bonus && old['overtimePaise']==overtime && old['deductionPaise']==deduction;
      if (same && attendanceAdjustment==null) return old;
      await requireAdmin(profile, adminPassword);
    }
    final alreadyPaid = paid(old);
    if (amount < alreadyPaid) throw StateError('Net salary cannot be lower than the payments already recorded.');
    final row = <String, dynamic>{...old, 'id': id, 'staffId': employee['id'],
      'teacherId': employee['teacherId'] ?? '', 'employeeId':employee['employeeId']??employee['teacherId']??'', 'name': employee['name'], 'role': employee['role'],
      'designation': employee['designation'], 'month': month, 'basicPaise': basic,
      'allowancePaise': allowance, 'bonusPaise': bonus, 'overtimePaise': overtime,
      'deductionPaise': deduction, 'netPaise': amount, 'amount': amount / 100,
      if(attendanceAdjustment!=null)'attendanceAdjustment':attendanceAdjustment,
      if(attendanceAdjustment!=null)'attendanceSummary':'${(attendanceAdjustment['unpaidDates'] as List).length} approved unpaid days',
      'paidPaise': alreadyPaid, 'balancePaise': amount - alreadyPaid,
      'status': alreadyPaid == amount ? 'Paid' : alreadyPaid == 0 ? 'Pending' : 'Part paid',
      'updatedAt': DateTime.now().millisecondsSinceEpoch};
    final batch = FirebaseFirestore.instance.batch();
    batch.requireUnchanged(ref, before);
    batch.set(ref, row);
    await batch.commit();
    return row;
  });
  static Future<void> recordPayment(String profile, String id, int amount, {required String paymentId,
      required DateTime date, required String mode, String reference = ''}) => _serial(() async {
    await _durable(profile);
    if (amount <= 0 || paymentId.isEmpty || !['Cash', 'Bank transfer', 'UPI', 'Cheque'].contains(mode)) throw ArgumentError('Enter a valid payment amount and method.');
    final ref = FirebaseFirestore.instance.collection('teacher_salary').doc(id);
    final row = (await ref.get()).data();
    _sameSchool(profile);
    if (row == null || row['netPaise'] is! num) throw StateError('Create a monthly salary record first.');
    final payments = List<dynamic>.from(row['payments'] as List? ?? []);
    if (payments.any((p) => p is! Map)) throw StateError('Stored payment history requires review. Original payments retained.');
    final prior = payments.where((p) => p is Map && p['id'] == paymentId).toList();
    if (prior.isNotEmpty) {
      // A repeated submit is idempotent only for this exact financial intent.
      // Reusing an ID for a correction must not falsely report a saved change.
      final same = prior.length == 1 && prior.single['amountPaise'] == amount &&
          prior.single['date'] == date.toIso8601String() &&
          prior.single['mode'] == mode && prior.single['reference'] == reference.trim();
      if (!same) throw StateError('Payment identity already belongs to different details. Original payment retained; review the correction.');
      return;
    }
    final next = paid(row) + amount;
    if (next > total(row)) throw StateError('Payment exceeds the remaining salary balance.');
    await WindowsLocalSecurity.initialize();
    _sameSchool(profile);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    payments.add({'id': paymentId, 'amountPaise': amount, 'date': date.toIso8601String(), 'mode': mode, 'reference': reference.trim(), 'timeRecorded': true, 'recordedAt': timestamp,
      if (WindowsLocalSecurity.configured) 'recordedBy': WindowsLocalSecurity.adminId});
    final batch = FirebaseFirestore.instance.batch();
    batch.requireUnchanged(ref, row);
    batch.set(ref, {'payments': payments, 'paidPaise': next, 'balancePaise': total(row) - next,
      'status': next == total(row) ? 'Paid' : 'Part paid', 'updatedAt': timestamp}, const SetOptions(merge: true));
    await batch.commit();
  });

  /// One guarded local transaction: all reviewed entries are saved together,
  /// or none are. Cloud delivery remains independently acknowledged per row.
  static Future<void> recordBulkPayments(String profile,List<Map<String,dynamic>> intents,
      {required DateTime date,required String mode,String reference=''})=>_serial(()async{
    await _durable(profile);
    if(intents.isEmpty||intents.length>200||!['Cash','Bank transfer','UPI','Cheque'].contains(mode))throw ArgumentError('Select 1–200 staff and a payment method.');
    await WindowsLocalSecurity.initialize();
    _sameSchool(profile);
    final db=FirebaseFirestore.instance,batch=db.batch();
    final rowIds=<String>{},paymentIds=<String>{};
    final timestamp=DateTime.now().millisecondsSinceEpoch;
    final journalEntries=<Map<String,dynamic>>[];
    int changed=0;
    for(final intent in intents){
      final id=intent['id'],paymentId=intent['paymentId'],amount=intent['amountPaise'];
      if(id is! String||id.isEmpty||!rowIds.add(id)||paymentId is! String||paymentId.isEmpty||!paymentIds.add(paymentId)||amount is! int||amount<=0)throw ArgumentError('Invalid or repeated bulk payment entry.');
      journalEntries.add({'id':id,'paymentId':paymentId,'amountPaise':amount});
      final ref=db.collection('teacher_salary').doc(id);
      final row=(await ref.get()).data();
      _sameSchool(profile);
      if(row==null||row['netPaise'] is! num)throw StateError('A selected salary record is missing. No bulk payments saved.');
      final payments=List<dynamic>.from(row['payments'] as List? ?? []);
      if(payments.any((p)=>p is! Map))throw StateError('Payment history requires review.');
      final prior=payments.where((p)=>p is Map&&p['id']==paymentId).toList();
      if(prior.isNotEmpty){
        if(prior.length!=1||prior.single['amountPaise']!=amount||prior.single['date']!=date.toIso8601String()||prior.single['mode']!=mode||prior.single['reference']!=reference.trim())throw StateError('Bulk payment identity conflict.');
        continue;
      }
      final remaining=total(row)-paid(row);
      if(remaining!=amount)throw StateError('A selected salary balance changed. Refresh and review all amounts. No bulk payments saved.');
      final next=paid(row)+amount;
      payments.add({'id':paymentId,'amountPaise':amount,'date':date.toIso8601String(),'mode':mode,'reference':reference.trim(),'timeRecorded':true,'recordedAt':timestamp,
        if(WindowsLocalSecurity.configured)'recordedBy':WindowsLocalSecurity.adminId});
      batch.requireUnchanged(ref,row);
      batch.update(ref,{'payments':payments,'paidPaise':next,'balancePaise':total(row)-next,'status':'Paid','updatedAt':timestamp});
      changed++;
    }
    _sameSchool(profile);
    final batchId='salary-bulk-'+sha256.convert(utf8.encode(jsonEncode(journalEntries.map((e)=>e['paymentId']).toList()..sort((a,b)=>a.toString().compareTo(b.toString()))))).toString();
    final journalRef=db.collection('_local_salary_bulk_journal').doc(batchId);
    final old=(await journalRef.get()).data();
    _sameSchool(profile);
    final identity={'entries':journalEntries,'date':date.toIso8601String(),'mode':mode,'reference':reference.trim(),
      'schoolId':db.activeProfileIdentity['schoolSyncId']??''};
    if(old!=null){
      if(jsonEncode(old['identity'])!=jsonEncode(identity))throw StateError('Bulk payment journal identity conflict.');
    }else{
      batch.requireUnchanged(journalRef,null);
      batch.set(journalRef,{'id':batchId,'identity':identity,'recordedAt':timestamp});
    }
    if(changed>0||old==null)await batch.commit();
  });
  static bool containsBulkPayment(Map? row,Map entry,Map identity,String school){
    if(row==null||school.isEmpty||row['schoolId']!=school||row['_syncDeleted']==true||
        row['id']!=null&&row['id']!=entry['id']||row['payments'] is! List)return false;
    final found=(row['payments'] as List).where((p)=>p is Map&&p['id']==entry['paymentId']).toList();
    return found.length==1&&found.single['amountPaise']==entry['amountPaise']&&
      found.single['date']==identity['date']&&found.single['mode']==identity['mode']&&found.single['reference']==identity['reference'];
  }
  static Future<List<Map<String,dynamic>>> bulkVerification(String profile)async{
    _sameSchool(profile);
    final db=FirebaseFirestore.instance,school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    final journals=(await db.collection('_local_salary_bulk_journal').get()).docs;
    final result=<Map<String,dynamic>>[];
    for(final journal in journals){
      final data=journal.data(),identity=data['identity'];
      if(identity is! Map||identity['schoolId']!=school||identity['entries'] is! List)continue;
      final entries=<Map<String,dynamic>>[];
      for(final raw in identity['entries'] as List){
        if(raw is! Map||raw['id'] is! String||raw['paymentId'] is! String)continue;
        _sameSchool(profile);
        final id=raw['id'] as String;
        final baselineKey=base64Url.encode(utf8.encode('teacher_salary\\n$id')).replaceAll('=', '');
        final baseline=(await db.collection('_windows_sync_baselines').doc(baselineKey).get()).data();
        final drive=(await db.collection('_windows_verified_cloud_records').doc(sheetRecoveryCacheKey('teacher_salary',id)).get()).data();
        _sameSchool(profile);
        final canonical=baseline?['record'],driveRecord=drive?['record'];
        final rev=canonical is Map?canonical['_syncRevision']:null;
        final edge=rev is String&&rev.startsWith('live-')&&baseline?['revision']==rev&&containsBulkPayment(canonical as Map,raw,identity,school);
        final driveFromBaseline=canonical is Map&&isDriveRecoveryRevision(rev)&&baseline?['revision']==rev&&containsBulkPayment(canonical,raw,identity,school);
        final driveVerified=driveFromBaseline||drive?['schoolId']==school&&drive?['collection']=='teacher_salary'&&drive?['documentId']==id&&
          driveRecord is Map&&isDriveRecoveryRevision(driveRecord['_syncRevision'])&&containsBulkPayment(driveRecord,raw,identity,school);
        entries.add({...Map<String,dynamic>.from(raw),'cloudflareRecordVerified':edge,'driveRecordVerified':driveVerified});
      }
      result.add({'id':journal.id,'recordedAt':data['recordedAt'],'entries':entries});
    }
    result.sort((a,b)=>((b['recordedAt'] as num?)??0).compareTo((a['recordedAt'] as num?)??0));
    return result;
  }
  /// Approval is attached to each salary row, not a separate unsynchronised UI flag.
  static Future<void> setSalaryLocked(String profile,String id,{required bool locked,required String adminPassword})=>_serial(()async{
    await requireAdmin(profile,adminPassword);
    await _durable(profile);
    final db=FirebaseFirestore.instance,ref=db.collection('teacher_salary').doc(id);
    final old=(await ref.get()).data();
    _sameSchool(profile);
    if(old==null||old['netPaise'] is! num)throw StateError('Modern salary record required.');
    if((old['salaryLocked']==true)==locked)return;
    await WindowsLocalSecurity.initialize();
    await requireAdmin(profile,adminPassword);
    final history=List<dynamic>.from(old['salaryLockHistory'] as List? ?? []);
    history.add({'id':SchoolPersonIdentity.newGeneration(),'locked':locked,'at':DateTime.now().millisecondsSinceEpoch,
      if(WindowsLocalSecurity.configured)'recordedBy':WindowsLocalSecurity.adminId});
    final batch=db.batch();
    batch.requireUnchanged(ref,old);
    batch.update(ref,{'salaryLocked':locked,'salaryLockHistory':history,'updatedAt':DateTime.now().millisecondsSinceEpoch});
    await batch.commit();
  });
  /// A payment correction is a new immutable event, not a rewrite of the
  /// original record. Every write re-reads the current row under the existing
  /// serialized school-local queue before checking its expected amount.
  static Future<void> correctPayment(
    String profile,
    String salaryRowId,
    String paymentId, {
    required int expectedPaise,
    required int correctedPaise,
    required String reason,
    required String correctionId,
    required String adminPassword,
    bool reverse = false,
  }) => _serial(() async {
    await requireAdmin(profile, adminPassword);
    await _durable(profile);
    final explanation = SalaryPaymentCorrectionPolicy.validateNote(reason);
    if (correctedPaise < 0 || (reverse ? correctedPaise != 0 : correctedPaise == 0) || correctedPaise == expectedPaise ||
        expectedPaise <= 0 || correctionId.trim().isEmpty) {
      throw StateError('Enter a different positive amount, or use the explicit reversal action.');
    }
    final doc = FirebaseFirestore.instance.collection('teacher_salary').doc(salaryRowId);
    final row = (await doc.get()).data();
    _sameSchool(profile);
    if (row == null || (row['id'] != salaryRowId && row['id'] != null) ||
        (row['schoolId'] != null &&
            row['schoolId'] != FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'])) {
      throw StateError('Salary record or school changed. Reopen Staff Salary.');
    }
    if(row['month'] is String)await _requireMonthOpen(profile,row['month'] as String);
    if(row['salaryLocked']==true)throw StateError('Salary is approved and locked. Reopen it before correcting a payment.');
    final payments = List<dynamic>.from(row['payments'] as List? ?? []);
    final matched = payments.where((v) => v is Map && v['id'] == paymentId).toList();
    if (matched.length != 1) throw StateError(
      'Original itemized payment not found. Legacy summaries cannot be silently modified.');
    final corrections = List<dynamic>.from(row['paymentCorrections'] as List? ?? []);
    final previous = corrections.where((v) => v is Map && v['id'] == correctionId).toList();
    if (previous.isNotEmpty) {
      if (previous.length != 1 || previous.single['paymentId'] != paymentId ||
          previous.single['previousPaise'] != expectedPaise ||
          previous.single['correctedPaise'] != correctedPaise ||
          previous.single['reason'] != explanation) {
        throw StateError('Correction ID conflicts with another operation.');
      }
      return; // A confirmed retry never creates a duplicate correction.
    }
    final effective = SalaryPaymentCorrectionPolicy.effectiveAmount(
        Map<String,dynamic>.from(matched.single as Map), corrections);
    if (effective != expectedPaise) throw StateError(
        'Someone modified this payment. Refresh and review before saving again.');
    final next = paid(row) + correctedPaise - effective;
    if (next < 0 || next > total(row)) throw StateError(
      'Correction exceeds the saved net salary. Review Edit salary first; original payment retained.');
    await WindowsLocalSecurity.initialize();
    _sameSchool(profile);
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    corrections.add({
      'id': correctionId,
      'paymentId': paymentId,
      'originalPaise': (matched.single as Map)['amountPaise'],
      'previousPaise': effective,
      'correctedPaise': correctedPaise,
      'differencePaise': correctedPaise - effective,
      'reason': explanation,
      'eventType': reverse ? 'reversal' : 'correction',
      'authorizedBy': WindowsLocalSecurity.adminId,
      'correctedAt': timestamp,
    });
    _sameSchool(profile);
    await requireAdmin(profile, adminPassword);
    final batch = FirebaseFirestore.instance.batch();
    batch.requireUnchanged(doc, row);
    batch.set(doc, {
      'paymentCorrections': corrections,
      'paidPaise': next, 'balancePaise': total(row) - next,
      'status': next == total(row) ? 'Paid' : next == 0 ? 'Pending' : 'Part paid',
      'updatedAt': timestamp,
    }, const SetOptions(merge: true));
    await batch.commit();
  });
}

class StaffSalaryScreen extends StatefulWidget {
  const StaffSalaryScreen({super.key});
  @override
  State<StaffSalaryScreen> createState() => _StaffSalaryScreenState();
}
class _StaffSalaryScreenState extends State<StaffSalaryScreen> {
  late final String _profile;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _staff = [], _rows = [];
  bool _loading = true, _local = true, _monthClosed=false;
  String _search = '', _role = 'All staff';
  String? _error;
  String _schoolName='';
  final Set<String> _selected = {};
  bool _working = false;
  int _loadGeneration = 0;
  StreamSubscription<QuerySnapshot<Map<String,dynamic>>>? _salarySubscription;
  StreamSubscription<DocumentSnapshot<Map<String,dynamic>>>? _monthSubscription;
  @override
  void initState() { super.initState(); _profile = FirebaseFirestore.instance.activeProfileId; _load(); }
  @override
  void dispose() { _loadGeneration++; _salarySubscription?.cancel(); _monthSubscription?.cancel(); super.dispose(); }
  void _changeMonth(DateTime month) {
    setState(() { _month = DateTime(month.year,month.month); _selected.clear(); _rows=[]; });
    _load();
  }
  Future<void> _load() async {
    if(!mounted)return;
    final generation = ++_loadGeneration;
    final month = StaffPayroll.monthKey(_month);
    final previous = _salarySubscription;
    final previousMonth = _monthSubscription;
    _salarySubscription = null;
    _monthSubscription=null;
    setState(() { _loading = true; _error = null; });
    try {
      await previous?.cancel();
      await previousMonth?.cancel();
      if(!mounted||generation!=_loadGeneration)return;
      StaffPayroll._sameSchool(_profile);
      final people = await StaffPayroll.staff(_profile);
      final query = FirebaseFirestore.instance.collection('teacher_salary').where('month',isEqualTo:month);
      final salary = await query.get();
      final branding=(await FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache').get()).data();
      final local = await FirebaseFirestore.instance.localPersistenceEnabled();
      final closed=await StaffPayroll.monthClosed(_profile,month);
      StaffPayroll._sameSchool(_profile);
      if (mounted && generation == _loadGeneration) setState(() {
        _schoolName=branding?['schoolName']?.toString()??'';
        _staff = people; _rows = salary.docs.map((d) => {...d.data(), 'id': d.id}).toList(); _local = local; _monthClosed=closed;
      });
      if(mounted&&generation==_loadGeneration){
        _monthSubscription=FirebaseFirestore.instance.collection('school_settings').doc(StaffPayroll.monthControlId(month)).snapshots().listen((snapshot){
          if(mounted&&generation==_loadGeneration&&FirebaseFirestore.instance.activeProfileId==_profile)setState(()=>_monthClosed=snapshot.data()?['closed']==true);
        },onError:(Object error){if(mounted&&generation==_loadGeneration)setState(()=>_error='Month control refresh failed: $error');});
        _salarySubscription=query.snapshots().listen((snapshot){
          if(!mounted||generation!=_loadGeneration||FirebaseFirestore.instance.activeProfileId!=_profile)return;
          setState(()=>_rows=snapshot.docs.map((d)=>{...d.data(),'id':d.id}).toList());
        },onError:(Object error){
          if(mounted&&generation==_loadGeneration)setState(()=>_error='Salary live refresh unavailable: $error');
        });
      }
    } catch (e) { if (mounted && generation == _loadGeneration) setState(() => _error = '$e'); }
    finally { if (mounted && generation == _loadGeneration) setState(() => _loading = false); }
  }
  Future<void> _editor(String title, List<Widget> Function(StateSetter) fields, Future<void> Function() save, {String? paymentName, String Function()? paymentAmount}) async {
    bool saving = false; String? error;
    final changed = await showDialog<bool>(context: context, barrierDismissible: false, builder: (ctx) { WindowsAppearance.watch(ctx); return  StatefulBuilder(builder: (ctx, setD) { WindowsAppearance.watch(ctx); return  PopScope(
      canPop: !saving, child: AlertDialog(title: Text(title), content: SizedBox(width: 470,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [...fields(setD).expand((w) => [w, SizedBox(height: 14)]),
            if (error != null) Text(error!, style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent)))]))),
        actions: [TextButton(onPressed: saving ? null : () => Navigator.pop(ctx, false), child: Text('Cancel')),
          FilledButton(onPressed: saving ? null : () async {
            setD(() { saving = true; error = null; });
            try {
              if (paymentName != null) {
                final confirmed = await confirmSchoolPayment(ctx, name: paymentName,
                  collecting: false, amount: paymentAmount!());
                if (!confirmed) {
                  if (ctx.mounted) setD(() => saving = false);
                  return;
                }
                StaffPayroll._sameSchool(_profile);
              }
              await save(); if (ctx.mounted) Navigator.pop(ctx, true);
            }
            catch (e) { if (ctx.mounted) setD(() { saving = false; error = '$e'; }); }
          }, child: Text(saving ? 'Saving…' : paymentName == null ? 'Save' : 'Pay'))])); }); });
    if (changed == true && mounted) await _load();
  }
  Future<void> _salary(Map<String, dynamic> person, Map<String, dynamic>? old) async {
    final month = StaffPayroll.monthKey(_month);
    var adminPassword = old == null ? null : await _adminAuthorization('Edit Salary');
    if ((old != null && adminPassword == null) || !mounted) return;
    const keys = ['basicPaise', 'allowancePaise', 'bonusPaise', 'overtimePaise', 'deductionPaise'];
    const labels = ['Basic salary', 'Allowances', 'Bonus', 'Overtime', 'Deductions / advance adjustment'];
    final template=old==null?await StaffPayroll.structure(_profile,person['id'].toString()):null;
    if(!mounted)return;
    final present=await StaffPayroll.verifiedAttendanceDays(_profile,person,month);
    final workingDays=await StaffPayroll.loadWorkingDays(_profile,month);
    if(!mounted)return;
    final priorAttendance=old?['attendanceAdjustment'] is Map?Map<String,dynamic>.from(old!['attendanceAdjustment'] as Map):<String,dynamic>{};
    final controllers = [for (final k in keys) TextEditingController(text: StaffPayroll.format((((old??template)?[k] as num?)?.toInt() ?? 0)-(k=='deductionPaise'?((priorAttendance['amountPaise'] as num?)?.toInt()??0):0)))];
    final unpaid=TextEditingController(text:(priorAttendance['unpaidDates'] as List? ?? []).join(', '));
    final rate=TextEditingController(text:StaffPayroll.format((priorAttendance['ratePaise'] as num?)?.toInt()??0));
    final reason=TextEditingController(text:priorAttendance['reason']?.toString()??'');
    Map<String,dynamic>? adjustment(){
      final dates=StaffPayroll.validatedUnpaidDays(month,unpaid.text,present,DateTime.now(),workingDays:workingDays);
      if(dates.isEmpty&&priorAttendance.isEmpty)return null;
      final perDay=StaffPayroll.money(rate.text);
      if(dates.isNotEmpty&&perDay<=0)throw StateError('Enter a positive approved deduction per day.');
      if(reason.text.trim().isEmpty)throw StateError('Enter the approved attendance adjustment reason.');
      return {'unpaidDates':dates.toList()..sort(),'ratePaise':perDay,'amountPaise':dates.length*perDay,'reason':reason.text.trim()};
    }
    await _editor('${person['name']} • $month', (setD) {
      String net = '—';
      try { final v = controllers.map((c) => StaffPayroll.money(c.text)).toList(); net = StaffPayroll.format(StaffPayroll.net(basic:v[0],allowance:v[1],bonus:v[2],overtime:v[3],deduction:v[4]+((adjustment()?['amountPaise'] as int?)??0))); } catch (_) {}
      return [for (var i = 0; i < controllers.length; i++) TextField(controller: controllers[i],
        keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setD(() {}),
        decoration: InputDecoration(labelText: labels[i], prefixText: '₹ ')),
        Text('School working days: ${workingDays.length} • Recorded QR present days: ${present.where(workingDays.contains).length}. Closed days cannot be deducted. Missing scans do not establish absence. Enter only approved unpaid dates; paid leave is excluded.'),
        TextField(controller:unpaid,onChanged:(_)=>setD((){}),decoration:const InputDecoration(labelText:'Approved unpaid dates (YYYY-MM-DD, comma separated)')),
        TextField(controller:rate,onChanged:(_)=>setD((){}),keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Approved deduction per day',prefixText:'₹ ')),
        OutlinedButton(onPressed:workingDays.isEmpty?null:(){try{final daily=StaffPayroll.proratedDailyRate(StaffPayroll.money(controllers.first.text),workingDays.length);setD(()=>rate.text=StaffPayroll.format(daily));}catch(_){setD(()=>rate.text='');}},child:const Text('Calculate rate from basic salary / working days')),
        TextField(controller:reason,onChanged:(_)=>setD((){}),decoration:const InputDecoration(labelText:'Attendance adjustment approval / reason')),
        Text('Net salary: ₹$net', style: TextStyle(fontFamily: 'Segoe UI', fontSize: 20, fontWeight: FontWeight.bold)),
        Text('Salary changes preserve all recorded payments.')];
    }, () async {
      final v = controllers.map((c) => StaffPayroll.money(c.text)).toList();
      final attendance=adjustment();
      if(attendance!=null&&adminPassword==null){
        adminPassword=await _adminAuthorization('Approve Attendance Deduction');
        if(adminPassword==null)throw StateError('Attendance adjustment was not authorized.');
      }
      await StaffPayroll.save(_profile, person, month, basic:v[0],allowance:v[1],bonus:v[2],overtime:v[3],deduction:v[4]+((attendance?['amountPaise'] as int?)??0),adminPassword:adminPassword,attendanceAdjustment:attendance);
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in [...controllers,unpaid,rate,reason]) { c.dispose(); }
  }
  Future<void> _payment(Map<String, dynamic> row) async {
    final amount = TextEditingController(text: StaffPayroll.format(StaffPayroll.total(row) - StaffPayroll.paid(row)));
    final reference = TextEditingController();
    var mode = 'Bank transfer'; var date = DateTime.now();
    final paymentId = 'payment:${SchoolPersonIdentity.newGeneration()}';
    await _editor('Record payment • ${row['name']}', (setD) => [
      TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ ')),
      DropdownButtonFormField<String>(isExpanded: true, initialValue: mode, items: ['Cash', 'Bank transfer', 'UPI', 'Cheque'].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(), onChanged: (v) => setD(() => mode = v!)),
      TextButton.icon(icon: Icon(Icons.event), label: Text('${date.day}/${date.month}/${date.year}'), onPressed: () async {
        final selected = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2000), lastDate: DateTime.now());
        if (selected != null) setD(() => date = DateTime(selected.year, selected.month, selected.day, date.hour, date.minute, date.second));
      }),
      TextButton.icon(icon: Icon(Icons.schedule), label: Text('Payment time: ${salaryPaymentTime(date)}'), onPressed: () async {
        final selected = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(date));
        if (selected != null) setD(() => date = DateTime(date.year, date.month, date.day, selected.hour, selected.minute));
      }),
      TextField(controller: reference, decoration: const InputDecoration(labelText: 'Payment reference / note')),
      Text('This records a payment already made. It does not transfer money.'),
    ], () => StaffPayroll.recordPayment(_profile, row['id'].toString(), StaffPayroll.money(amount.text), paymentId: paymentId, date: date, mode: mode, reference: reference.text), paymentName: row['name']?.toString() ?? 'Staff member',
      paymentAmount: () {
        final value = StaffPayroll.money(amount.text);
        if (value <= 0 || value > StaffPayroll.total(row) - StaffPayroll.paid(row)) throw StateError('Enter an amount within the remaining salary balance.');
        return '₹${StaffPayroll.format(value)}';
      });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    amount.dispose(); reference.dispose();
  }

  Future<String?> _adminAuthorization(String action) async {
    StaffPayroll._sameSchool(_profile);
    if (!await WindowsSectionLocks.configured('admin_section')) {
      if(mounted) setState(() => _error = 'Configure the Admin Section password in Password Management before changing financial records.');
      return null;
    }
    if(!mounted) return null;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(context:context,barrierDismissible:false,builder:(dialog){
        String? error;
        bool checking=false;
        return StatefulBuilder(builder:(ctx,refresh)=>AlertDialog(
          title:Text('Admin Password • $action'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            TextField(controller:controller,obscureText:true,autofocus:true,enableSuggestions:false,autocorrect:false,
              decoration:const InputDecoration(labelText:'Admin Section password')),
            if(error!=null)Text(error!),
          ]),
          actions:[
            TextButton(onPressed:checking?null:()=>Navigator.pop(dialog),child:const Text('Cancel')),
            FilledButton(onPressed:checking?null:()async{
              refresh(()=>checking=true);
              try {
                await StaffPayroll.requireAdmin(_profile,controller.text);
                if(dialog.mounted)Navigator.pop(dialog,controller.text);
              } catch (_) {
                if(ctx.mounted)refresh((){checking=false;error='Admin password incorrect or school changed.';});
              }
            },child:const Text('Verify')),
          ]));
      });
    } finally {
      await Future<void>.delayed(const Duration(milliseconds:250));
      controller.dispose();
    }
  }

  Future<void> _correctPayment(Map<String,dynamic> salary,{bool reverse=false}) async {
    StaffPayroll._sameSchool(_profile);
    final raw = List<dynamic>.from(salary['payments'] as List? ?? []);
    final history = List<dynamic>.from(salary['paymentCorrections'] as List? ?? []);
    final eligible = <Map>[];
    try {
      for(final p in raw.whereType<Map>()) {
        if(p['id'] is String && p['amountPaise'] is num &&
           SalaryPaymentCorrectionPolicy.effectiveAmount(Map<String,dynamic>.from(p),history)>0) eligible.add(p);
      }
    } catch(e) {
      if(mounted)setState(()=>_error='$e');
      return;
    }
    if (eligible.isEmpty) {
      if(mounted)setState(() => _error = 'No active itemized payment available. Legacy balances require manual review.');
      return;
    }
    final password = await _adminAuthorization(reverse?'Reverse Payment':'Modify Payment');
    if(password==null||!mounted)return;
    StaffPayroll._sameSchool(_profile);
    final corrections = List<dynamic>.from(salary['paymentCorrections'] as List? ?? []);
    final choices = <String,Map<String,dynamic>>{};
    for(final rawPayment in eligible) {
      final payment = Map<String,dynamic>.from(rawPayment);
      final id = payment['id'] as String;
      if(choices.containsKey(id)) continue;
      choices[id]=payment;
    }
    var selected = choices.keys.first;
    final amount = TextEditingController();
    final note = TextEditingController();
    int effective(String id) => SalaryPaymentCorrectionPolicy.effectiveAmount(
      choices[id]!,corrections);
    amount.text=reverse?'0.00':StaffPayroll.format(effective(selected));
    final correctionId='correction:${SchoolPersonIdentity.newGeneration()}';
    try {
      await _editor('${reverse?'Reverse Payment':'Modify Payment'} • ${salary['name']}', (setD) => [
        DropdownButtonFormField<String>(
          value:selected,isExpanded:true,
          decoration:const InputDecoration(labelText:'Recorded payment to correct'),
          items:[for(final item in choices.entries)DropdownMenuItem(
            value:item.key,
            child:Text('Original ₹${StaffPayroll.format((item.value['amountPaise'] as num).toInt())} • ${item.key}',
              maxLines:1,overflow:TextOverflow.ellipsis))],
          onChanged:(v){if(v!=null)setD((){
            selected=v;amount.text=reverse?'0.00':StaffPayroll.format(effective(selected));
          });},
        ),
        Text('Previous recorded: ₹${StaffPayroll.format(effective(selected))}'),
        if(reverse) const Text('Reversal cancels the recorded payment amount. It does not refund or transfer money.') else TextField(controller:amount,
          keyboardType:const TextInputType.numberWithOptions(decimal:true),
          decoration:const InputDecoration(labelText:'Corrected recorded amount',prefixText:'₹ '),
          onChanged:(_)=>setD((){})),
        Builder(builder: (_) {
          final candidate=(() {
            try {return StaffPayroll.money(amount.text);} catch (_) {return 0;}
          })();
          final change=candidate-effective(selected);
          return Text('Adjustment: ${change>=0?'+':''}₹${StaffPayroll.format(change)} • Original entry remains in audit history.');
        }),
        TextField(controller:note,minLines:5,maxLines:9,maxLength:3500,
          decoration:const InputDecoration(labelText:'Reason / detailed audit explanation',
            hintText:'Explain what was entered, why it was wrong, what evidence was checked, and who approved the correction.'),
          onChanged:(_)=>setD((){})),
        Text('Explanation: ${SalaryPaymentCorrectionPolicy.wordCount(note.text)} / 100–300 words required.'),
        const Text('This updates the recorded salary payment, not an actual bank transfer. The original event and every correction remain visible in the payslip and history.'),
      ], () async {
        final expected=effective(selected);
        final corrected=StaffPayroll.money(amount.text);
        await StaffPayroll.correctPayment(_profile,salary['id'].toString(),selected,
          expectedPaise:expected,correctedPaise:corrected,
          reason:note.text,correctionId:correctionId,adminPassword:password,reverse:reverse);
      });
    } finally {
      await Future<void>.delayed(const Duration(milliseconds:250));
      amount.dispose();note.dispose();
    }
  }

  Future<void> _history([Map<String, dynamic>? row]) => Navigator.push<void>(context,
    MaterialPageRoute(builder: (_) => StaffSalaryHistoryScreen(profile: _profile,
      staffId: row == null ? null : row['staffId']?.toString() ?? 'legacy:${row['id']}', salaryRowId: row?['id']?.toString(), teacherId: row?['teacherId']?.toString(),
      staffName: row?['name']?.toString())));
  List<Map<String,dynamic>> get _monthRows => _rows.where((r) => r['month'] == StaffPayroll.monthKey(_month)).toList();
  Future<void> _output({bool csv = false, Map<String,dynamic>? row}) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      StaffPayroll._sameSchool(_profile);
      final rows = row == null ? _monthRows : [row];
      if (rows.isEmpty) throw StateError('Create salary records for this month first.');
      if (csv) {
        String cell(Object? value) {
          var text = value?.toString() ?? '';
          if (RegExp(r'^[=+@\-\t\r]').hasMatch(text)) text = "'$text";
          return '"${text.replaceAll('"', '""')}"';
        }
        final content = ['Name,Employee ID,Role,Month,Basic,Allowances,Bonus,Overtime,Deductions,Net,Paid,Balance,Status',
          for (final r in rows) [r['name'],r['employeeId']??r['teacherId']??r['staffId'],r['role'],r['month'],
            StaffPayroll.format((r['basicPaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['allowancePaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['bonusPaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['overtimePaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format((r['deductionPaise'] as num?)?.toInt() ?? 0),
            StaffPayroll.format(StaffPayroll.total(r)),StaffPayroll.format(StaffPayroll.paid(r)),
            StaffPayroll.format(StaffPayroll.total(r)-StaffPayroll.paid(r)),r['status']].map(cell).join(',')].join('\r\n');
        await WindowsSavePdf.save(Uint8List.fromList(utf8.encode(content)), 'staff-salary-${StaffPayroll.monthKey(_month)}.csv', csv:true);
      } else {
        final r=rows.single;
        final bytes=await WindowsDocumentTemplates.selected('payslip',{
          ...r,'payslipRecordId':r['id'],'netPaise':StaffPayroll.total(r),'paidPaise':StaffPayroll.paid(r),
        });
        StaffPayroll._sameSchool(_profile);
        if(bytes==null)throw StateError('Selected payslip template could not be rendered.');
        if (mounted) await showDialog<void>(context:context,builder: (_) =>
          WindowsReceiptPrintDialog(
            receipt:Future.value(bytes),
            title:'Payslip • ${rows.single['name']}',
            subtitle:'${rows.single['month'] ?? ''} • Staff Salary',
            isCurrent:()=>FirebaseFirestore.instance.activeProfileId==_profile,
          ));
      }
    } catch(e) { if(mounted) setState(() => _error='$e'); }
    finally { if(mounted) setState(() => _working=false); }
  }
  Future<void> _advance(Map<String,dynamic> person) async{
    try{
      final staffId=(person['staffId']??person['id']).toString();
      final ledger=await StaffPayroll.advanceLedger(_profile,staffId);
      if(!mounted)return;
      final events=(ledger?['events'] as List? ?? []).whereType<Map>().toList();
      final password=await _adminAuthorization('Advance / Loan Ledger');
      if(password==null||!mounted)return;
      final amount=TextEditingController(),reference=TextEditingController();
      var type='advance';
      final id=SchoolPersonIdentity.newGeneration();
      try{
        await _editor('Advance / Loan • '+(person['name']?.toString()??staffId),(setD)=>[
          Text('Outstanding: ₹'+StaffPayroll.format((ledger?['balancePaise'] as int?)??0)),
          for(final e in events.reversed) Text('${e['type']} • ₹${StaffPayroll.format(e['amountPaise'] as int)} • ${e['reference']}'),
          const Divider(),
          DropdownButtonFormField<String>(initialValue:type,items:['advance','loan','repayment'].map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:(v)=>setD(()=>type=v!)),
          TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Amount',prefixText:'₹ ')),
          TextField(controller:reference,decoration:const InputDecoration(labelText:'Actual payment reference / evidence')),
          const Text('Record only an actual advance, loan or separate repayment. This does not transfer money or automatically deduct salary. Do not record the same repayment twice.'),
        ],()=>StaffPayroll.recordAdvance(_profile,staffId,type:type,amount:StaffPayroll.money(amount.text),eventId:id,reference:reference.text,adminPassword:password));
      }finally{
        await Future<void>.delayed(const Duration(milliseconds:250));
        amount.dispose();reference.dispose();
      }
    }catch(e){if(mounted)setState(()=>_error='$e');}
  }
  Future<void> _editStructure(Map<String,dynamic> person) async {
    try{
      final password=await _adminAuthorization('Salary Structure');
      if(password==null||!mounted)return;
      final staffId=person['id'].toString();
      final old=await StaffPayroll.structure(_profile,staffId);
      if(!mounted)return;
      const keys=['basicPaise','allowancePaise','deductionPaise'],labels=['Recurring basic salary','Recurring allowance','Recurring deduction'];
      final c=[for(final key in keys)TextEditingController(text:StaffPayroll.format((old?[key] as num?)?.toInt()??0))];
      try{
        await _editor('Salary Structure • ${person['name']}',(setD)=>[
          for(int i=0;i<c.length;i++)TextField(controller:c[i],keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:labels[i],prefixText:'₹ ')),
          const Text('This template is used only for new salary months. Existing payroll and payment history are not changed. Bonus and overtime remain monthly inputs.'),
        ],()async{
          await StaffPayroll.saveStructure(_profile,staffId,basic:StaffPayroll.money(c[0].text),allowance:StaffPayroll.money(c[1].text),deduction:StaffPayroll.money(c[2].text),adminPassword:password);
        });
      }finally{
        await Future<void>.delayed(const Duration(milliseconds:250));
        for(final controller in c)controller.dispose();
      }
    }catch(e){if(mounted)setState(()=>_error='$e');}
  }
  Future<void> _generateMonth() async {
    if(_working)return;
    final month=StaffPayroll.monthKey(_month);
    final password=await _adminAuthorization('Generate Monthly Salary');
    if(password==null||!mounted)return;
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('Generate salary • $month'),
      content:const Text('Create unpaid salary rows using each active staff member’s saved salary structure. Existing rows are skipped. No payment is recorded. Staff without a structure are skipped.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Generate'))]));
    if(confirmed!=true||!mounted)return;
    setState(()=>_working=true);
    try{
      final result=await StaffPayroll.generateMonth(_profile,month,adminPassword:password);
      if(mounted){
        await _load();
        if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Created: ${result['created']} • Already exists: ${result['existing']} • Missing structure: ${result['missing']}')));
      }
    }catch(e){if(mounted)setState(()=>_error='$e');}
    finally{if(mounted)setState(()=>_working=false);}
  }
  Future<void> _legacyReview() async{
    try{
      final rows=await StaffPayroll.legacyReview(_profile);
      if(!mounted)return;
      final selected=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Legacy Salary Review'),
        content:SizedBox(width:660,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('${rows.length} records requiring review. Original payment history is retained. No dates, payment IDs or transactions are invented.'),
          for(final row in rows)ListTile(title:Text('${row['name']??row['id']} • ${row['month']??'Unknown month'}'),
            subtitle:Text(row['reviewIssue'].toString()),trailing:row['canNormalize']==true?TextButton(onPressed:()=>Navigator.pop(ctx,row['id'].toString()),child:const Text('Review & normalize')):null),
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
      if(selected==null||!mounted)return;
      final password=await _adminAuthorization('Normalize Verified Legacy Fields');
      if(password==null||!mounted)return;
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Confirm normalization'),
        content:const Text('Confirm that the saved salary amount and status match the original school records. Only derived paise fields are added; no payment is created.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Normalize'))]));
      if(confirmed!=true||!mounted)return;
      await StaffPayroll.normalizeLegacy(_profile,selected,adminPassword:password);
      if(mounted)await _load();
    }catch(e){if(mounted)setState(()=>_error='$e');}
  }
  Future<void> _toggleMonth() async{
    if(_working)return;
    final month=StaffPayroll.monthKey(_month),closed=!_monthClosed;
    try{
      final password=await _adminAuthorization(closed?'Close Payroll Month':'Reopen Payroll Month');
      if(password==null||!mounted)return;
      final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
        title:Text((closed?'Close ':'Reopen ')+month),
        content:Text(closed?'Block new salary rows, salary edits and corrections for this month. Ordinary payment recording remains available. Cloud acceptance is separate from local save.':'Allow salary changes again. Individual approved salary locks remain in force.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm'))]));
      if(confirmed!=true||!mounted)return;
      setState(()=>_working=true);
      await StaffPayroll.setMonthClosed(_profile,month,closed:closed,adminPassword:password);
      if(mounted)await _load();
    }catch(e){if(mounted)setState(()=>_error='$e');}
    finally{if(mounted)setState(()=>_working=false);}
  }
  Future<void> _toggleSalaryLock(Map<String,dynamic> row) async {
    try{
      final locked=row['salaryLocked']!=true;
      final password=await _adminAuthorization(locked?'Approve & Lock Salary':'Reopen Salary');
      if(password==null||!mounted)return;
      await StaffPayroll.setSalaryLocked(_profile,row['id'].toString(),locked:locked,adminPassword:password);
      if(mounted)await _load();
    }catch(e){if(mounted)setState(()=>_error='$e');}
  }
  Future<void> _calculatePayroll() async {
    final person = await showDialog<Map<String,dynamic>>(context:context,builder:(ctx){ WindowsAppearance.watch(ctx); return SimpleDialog(title:Text('Select staff to calculate salary'),children:[for(final person in _staff) SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,person),child:Text('${person['name']} • ${person['employeeId']??person['teacherId']??person['id']} • ${person['role']}'))]); });
    if(person != null && mounted) await _salary(person,_monthRows.where((r)=>r['staffId']==person['id']).firstOrNull);
  }
  Future<void> _bulkVerification() async{
    try{
      final batches=await StaffPayroll.bulkVerification(_profile);
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Bulk Payment Verification'),
        content:SizedBox(width:650,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('This PC’s durable batches. Verified counts require matching original payment details in a verified record. Missing evidence is not a failed payment. Refresh after school sync.'),
          if(batches.isEmpty)const Text('No bulk payment batches recorded on this PC.'),
          for(final batch in batches.take(50))...[
            const Divider(),
            Text('Batch: '+batch['id'].toString()),
            Text('Local entries: '+(batch['entries'] as List).length.toString()),
            Text('Cloudflare record proof: '+(batch['entries'] as List).where((e)=>e['cloudflareRecordVerified']==true).length.toString()),
            Text('Drive record proof: '+(batch['entries'] as List).where((e)=>e['driveRecordVerified']==true).length.toString()),
            for(final e in (batch['entries'] as List).where((e)=>e['driveRecordVerified']!=true))Text('${e['paymentId']} • Drive not verified'),
          ],
        ]))),
        actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Close'))]));
    }catch(e){if(mounted)setState(()=>_error='$e');}
  }
  Future<void> _paySelected() async {
    final rows = _monthRows.where((r) => _selected.contains(r['staffId']) && StaffPayroll.paid(r)<StaffPayroll.total(r)).toList();
    if(rows.isEmpty) { setState(() => _error='Select staff with an unpaid salary record first.'); return; }
    if(_working)return;
    final intents=[for(final row in rows) {'id':row['id'],'paymentId':'payment:${SchoolPersonIdentity.newGeneration()}','amountPaise':StaffPayroll.total(row)-StaffPayroll.paid(row)}];
    final total=intents.fold<int>(0,(n,p)=>n+(p['amountPaise'] as int));
    var mode='Cash';
    final date=DateTime.now(),reference=TextEditingController();
    try{
      await _editor('Record Selected Payments • ${rows.length} staff',(setD)=>[
        const Text('Confirm only payments already made. All selected balances will be paid in full. The local save is atomic; cloud backup is verified separately.'),
        for(final row in rows)Text('${row['name']} • ₹${StaffPayroll.format(StaffPayroll.total(row)-StaffPayroll.paid(row))}'),
        Text('Total: ₹${StaffPayroll.format(total)}'),
        DropdownButtonFormField<String>(initialValue:mode,items:['Cash','Bank transfer','UPI','Cheque'].map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(v)=>setD(()=>mode=v!)),
        Text('Recorded payment date and time: ${salaryPaymentDate(date)} ${salaryPaymentTime(date)}'),
        TextField(controller:reference,decoration:const InputDecoration(labelText:'Shared payment reference / note')),
      ],() => StaffPayroll.recordBulkPayments(_profile,intents,date:date,mode:mode,reference:reference.text),
        paymentName:'${rows.length} selected staff',paymentAmount:()=> '₹${StaffPayroll.format(total)}');
    }finally{
      await Future<void>.delayed(const Duration(milliseconds:250));
      reference.dispose();
    }
  }
  static const _months=['January','February','March','April','May','June','July','August','September','October','November','December'];
  String get _monthLabel => '${_months[_month.month-1]} ${_month.year}';
  @override
  Widget build(BuildContext context) {WindowsAppearance.watch(context);
    final rows=_monthRows;
    final net=rows.fold<int>(0,(v,r)=>v+StaffPayroll.total(r));
    final paid=rows.fold<int>(0,(v,r)=>v+StaffPayroll.paid(r));
    final deductions=rows.fold<int>(0,(v,r)=>v+((r['deductionPaise'] as num?)?.toInt() ?? 0));
    final paidCount=rows.where((r)=>StaffPayroll.paid(r)>=StaffPayroll.total(r)).length;
    final people=_staff.where((s)=>(_role=='All staff'||StaffPayroll.displayCategory(s)==_role)&&'${s['name']} ${s['employeeId']} ${s['id']} ${s['designation']}'.toLowerCase().contains(_search.toLowerCase())).toList();
    final dark=Theme.of(context);
    return Theme(data:dark,child:Scaffold(appBar:AppBar(backgroundColor:WindowsAppearance.resolve(const Color(0xff0c233e)),
      title: Row(children:[Icon(Icons.account_balance_wallet,color: WindowsAppearance.foreground(Colors.lightBlueAccent)),SizedBox(width:16),
        Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Staff Salary',style:TextStyle(fontFamily: 'Segoe UI', fontSize:25,fontWeight:FontWeight.bold)),
          Text('Manage monthly salaries for teachers, office staff and school workers.',style:TextStyle(fontFamily: 'Segoe UI', fontSize:12,color:WindowsAppearance.foreground(Colors.white70)))])]),
      actions:[IconButton(tooltip:'Refresh',onPressed:_load,icon:Icon(Icons.refresh))]),
      body:_loading ? Center(child:CircularProgressIndicator()) : LayoutBuilder(builder:(context,constraints){ WindowsAppearance.watch(context); return
        ListView(padding:const EdgeInsets.all(20),children:[
          Wrap(spacing:12,runSpacing:12,crossAxisAlignment:WrapCrossAlignment.center,children:[
            IconButton(tooltip:'Previous month',onPressed:()=>_changeMonth(DateTime(_month.year,_month.month-1)),icon:Icon(Icons.chevron_left)),
            OutlinedButton.icon(icon:Icon(Icons.calendar_month),label:Text(_monthLabel),onPressed:() async {
              final day=await showDatePicker(context:context,initialDate:_month,firstDate:DateTime(2000),lastDate:DateTime(2100));
              if(day!=null&&mounted)_changeMonth(day);
            }),
            IconButton(tooltip:'Next month',onPressed:()=>_changeMonth(DateTime(_month.year,_month.month+1)),icon:Icon(Icons.chevron_right)),
            FilledButton.icon(onPressed:_staff.isEmpty||_monthClosed?null:_calculatePayroll,icon:Icon(Icons.calculate_outlined),label:Text('Calculate Payroll')),
            OutlinedButton.icon(onPressed:_working||_staff.isEmpty||_monthClosed?null:_generateMonth,icon:Icon(Icons.playlist_add),label:Text('Generate Monthly Salary')),
            OutlinedButton.icon(onPressed:_working?null:_toggleMonth,icon:Icon(_monthClosed?Icons.lock_open:Icons.lock),label:Text(_monthClosed?'Reopen Payroll Month':'Close Payroll Month')),
            FilledButton.icon(style:FilledButton.styleFrom(backgroundColor: WindowsAppearance.primary, foregroundColor: WindowsAppearance.onPrimary),onPressed:_selected.isEmpty?null:_paySelected,icon:Icon(Icons.done_all),label:Text('Record Selected Payments')),
            OutlinedButton.icon(onPressed:_working?null:_legacyReview,icon:Icon(Icons.fact_check_outlined),label:Text('Legacy Salary Review')),
            OutlinedButton.icon(onPressed:_working?null:_bulkVerification,icon:Icon(Icons.fact_check),label:Text('Bulk Verification')),
            OutlinedButton.icon(key: const ValueKey('salary-history'), onPressed:()=>_history(),icon:Icon(Icons.history),label:Text('Payment History')),
            OutlinedButton.icon(onPressed:_working?null:()=>_output(csv:true),icon:Icon(Icons.download_outlined),label:Text('Export CSV')),

          ]),SizedBox(height:18),
          Wrap(spacing:12,runSpacing:12,children:[
            _metric('Total Staff','${_staff.length}',WindowsAppearance.primary,Icons.groups_outlined,'${_staff.where((s)=>s['role']=='Teacher').length} Teachers'),
            _metric('Gross Salary','₹${StaffPayroll.format(net+deductions)}',WindowsAppearance.primary,Icons.currency_rupee,'Total earnings'),
            _metric('Total Deductions','₹${StaffPayroll.format(deductions)}',WindowsAppearance.foreground(Colors.redAccent),Icons.pie_chart_outline,'Recorded deductions'),
            _metric('Net payroll','₹${StaffPayroll.format(net)}',WindowsAppearance.primary,Icons.account_balance,'After all deductions'),
            _metric('Paid','₹${StaffPayroll.format(paid)}',Colors.green,Icons.check_circle_outline,'$paidCount staff paid'),
            _metric('Pending','₹${StaffPayroll.format(net-paid)}',Colors.orange,Icons.hourglass_empty,'Remaining balance'),
          ]),SizedBox(height:18),
          if(_monthClosed) const Text('Payroll month closed • salary changes blocked • payments still allowed'),
          if(!_local) Padding(padding:EdgeInsets.all(12),child:Text('Salary changes require durable school storage. The app will enable protected storage for this school before saving; if that fails no payment is recorded.')),
           Text('Records belong to the active school. Teacher salary appears in the teacher app after school sync.',style:TextStyle(fontFamily: 'Segoe UI', color:WindowsAppearance.foreground(Colors.white54),fontSize:12)),
          if(_error!=null) Padding(padding:const EdgeInsets.all(12),child:Text(_error!,style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.redAccent)))),
          SizedBox(height:16),
          Wrap(spacing:10,runSpacing:10,children:[
            for(final role in ['All staff','Teacher',...OtherStaffDirectory.roles])
              ChoiceChip(selectedColor:WindowsAppearance.background(const Color(0xff6252ee)),labelStyle: TextStyle(fontFamily: 'Segoe UI', color:WindowsAppearance.resolve(Colors.white)),label:Text('$role (${role=='All staff'?_staff.length:_staff.where((s)=>StaffPayroll.displayCategory(s)==role).length})'),selected:_role==role,onSelected:(_)=>setState(()=>_role=role)),
            SizedBox(width:320,child:TextField(onChanged:(v)=>setState(()=>_search=v),decoration:const InputDecoration(hintText:'Search by name, ID or department...',prefixIcon:Icon(Icons.search)))),
          ]),SizedBox(height:16),
          if(people.isEmpty) Padding(padding:EdgeInsets.all(30),child:Text('No staff found. Add teachers in Teachers and non-teaching staff in Other Staff.')),
          Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Card(child:SingleChildScrollView(scrollDirection:Axis.horizontal,child:DataTable(
            headingRowColor:WidgetStateProperty.all(WindowsAppearance.resolve(const Color(0xff172c42))),columnSpacing:14,dataRowMinHeight:64,dataRowMaxHeight:76,
            columns:[for(final label in ['Name / Employee ID','Role / Department','Attendance','Basic Pay','Allowances','Deductions','Net Salary','Status','Action'])DataColumn(label:Text(label))],
            rows:[for(final person in people)_tableRow(person,rows)],
          )))),if(constraints.maxWidth>=1350)...[SizedBox(width:14),SizedBox(width:270,child:_monthSummary(net,paid,deductions,paidCount,rows.length))]]),
          if(constraints.maxWidth<1350)_monthSummary(net,paid,deductions,paidCount,rows.length),
          for(final row in rows.where((r)=>!_staff.any((s)=>s['id']==r['staffId'])))
            Card(child:ListTile(title:Text('${row['name'] ?? row['teacherId'] ?? 'Previous staff'} • ₹${StaffPayroll.format(StaffPayroll.total(row))}'),subtitle:Text('${row['status'] ?? 'Previous record'} • Balance ₹${StaffPayroll.format(StaffPayroll.total(row)-StaffPayroll.paid(row))}'),trailing:Wrap(spacing:8,children:[
              if(row['netPaise'] is num && StaffPayroll.paid(row)<StaffPayroll.total(row)) TextButton(onPressed:()=>_payment(row),child:Text('Record payment')),
              if(StaffPayroll.paid(row)>0) TextButton(onPressed:()=>_correctPayment(row),child:Text('Modify payment')),
              if(StaffPayroll.paid(row)>0) TextButton(onPressed:()=>_correctPayment(row,reverse:true),child:Text('Reverse payment')),
              if((row['staffId']?.toString()??'').isNotEmpty)TextButton(onPressed:()=>_advance(row),child:Text('Advance ledger')),
              IconButton(tooltip:'Payment history',icon:Icon(Icons.history),onPressed:()=>_history(row)),
              IconButton(tooltip:'View payslip',icon:Icon(Icons.receipt_long),onPressed:_working?null:()=>_output(row:row)),
            ]))),
        ]); })));
  }
  Widget _metric(String label,String value,Color color,IconData icon,String detail)=>SizedBox(width:205,child:Container(
    padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:color.withValues(alpha:.12),border:Border.all(color:color.withValues(alpha:.35)),borderRadius:BorderRadius.circular(10)),
    child:Row(children:[CircleAvatar(backgroundColor:color.withValues(alpha:.6),child:Icon(icon,color:WindowsAppearance.onColor(color.withValues(alpha:.6)))),SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(label,style: TextStyle(fontFamily: 'Segoe UI', fontSize:12,color:WindowsAppearance.foreground(Colors.white70))),SizedBox(height:8),FittedBox(child:Text(value,style:TextStyle(fontFamily: 'Segoe UI', fontSize:22,fontWeight:FontWeight.bold))),SizedBox(height:8),Text(detail,style: TextStyle(fontFamily: 'Segoe UI', fontSize:10,color:WindowsAppearance.foreground(Colors.white54)))]))])));
  Widget _monthSummary(int net,int paid,int deductions,int count,int total)=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Text('$_monthLabel Summary',style:TextStyle(fontFamily: 'Segoe UI', fontSize:18,fontWeight:FontWeight.bold)),SizedBox(height:20),
    Center(child:SizedBox(width:110,height:110,child:Stack(alignment:Alignment.center,children:[
      SizedBox.expand(child:CircularProgressIndicator(value:net==0?0:paid/net,strokeWidth:14,backgroundColor: WindowsAppearance.background(Colors.orange),color: WindowsAppearance.foreground(Colors.cyan))),Text('$total\nSalary records',textAlign:TextAlign.center)]))),
    SizedBox(height:24),Text('Paid staff: $count'),const Divider(),Text('Gross Salary: ₹${StaffPayroll.format(net+deductions)}'),
    SizedBox(height:10),Text('Total Deductions: ₹${StaffPayroll.format(deductions)}'),const Divider(),Text('Net Payable: ₹${StaffPayroll.format(net)}'),
    SizedBox(height:10),Text('Paid Amount: ₹${StaffPayroll.format(paid)}',style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.greenAccent))),
    SizedBox(height:10),Text('Pending Amount: ₹${StaffPayroll.format(net-paid)}',style:TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.orangeAccent))),
  ])));
  DataRow _tableRow(Map<String,dynamic> person,List<Map<String,dynamic>> rows) {
    final row=rows.where((r)=>r['staffId']==person['id']).firstOrNull;
    String amount(String key)=>row==null?'—':'₹${StaffPayroll.format((row[key] as num?)?.toInt()??0)}';
    final status=row?['status']?.toString()??'Not set';
    final color=status=='Paid'?Colors.green:Colors.orange;
    return DataRow(selected:_selected.contains(person['id']),onSelectChanged:(value)=>setState((){if(value==true)_selected.add(person['id'].toString());else _selected.remove(person['id']);}),cells:[
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(person['name'].toString(),style:TextStyle(fontFamily: 'Segoe UI', fontWeight:FontWeight.bold)),Text((person['employeeId']??person['teacherId']??person['id']).toString(),style: TextStyle(fontFamily: 'Segoe UI', fontSize:11,color:WindowsAppearance.foreground(Colors.white54)))])),
      DataCell(Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.start,children:[Text(StaffPayroll.displayCategory(person)),Text(OtherStaffDirectory.suggestedDesignation(person),style: TextStyle(fontFamily: 'Segoe UI', fontSize:11,color:WindowsAppearance.foreground(Colors.white54)))])),
      DataCell(Tooltip(message:'Attendance deductions require administrator-confirmed unpaid dates and an approved rate.',child:Text(row?['attendanceSummary']?.toString()??'—'))),
      DataCell(Text(amount('basicPaise'))),DataCell(Text(amount('allowancePaise'))),DataCell(Text(amount('deductionPaise'))),DataCell(Text(row==null?'—':'₹${StaffPayroll.format(StaffPayroll.total(row))}')),
      DataCell(Chip(label:Text(row?['salaryLocked']==true?'$status • Locked':status),backgroundColor:color.withValues(alpha:.2))),
      DataCell(Row(children:[
        if(row==null)TextButton(onPressed:_monthClosed?null:()=>_salary(person,null),child:Text('Set salary'))
        else FilledButton.tonal(onPressed:_working?null:()=>_output(row:row),child:Text('View Payslip')),
        PopupMenuButton<String>(tooltip:'Salary actions',onSelected:(action){
          if(action=='edit')_salary(person,row);
          if(action=='structure')_editStructure(person);
          if(action=='advance')_advance(person);
          if(action=='lock'&&row!=null)_toggleSalaryLock(row);
          if(action=='pay'&&row!=null)_payment(row);
          if(action=='correct'&&row!=null)_correctPayment(row);
          if(action=='reverse'&&row!=null)_correctPayment(row,reverse:true);
          if(action=='history'&&row!=null)_history(row);
        },itemBuilder:(_)=>[
          PopupMenuItem(value:'edit',enabled:!_monthClosed,child:Text(row==null?'Set salary':'Edit salary')),
          const PopupMenuItem(value:'structure',child:Text('Salary Structure • Admin Password')),
          const PopupMenuItem(value:'advance',child:Text('Advance / Loan Ledger • Admin Password')),
          if(row!=null)PopupMenuItem(value:'lock',child:Text(row['salaryLocked']==true?'Reopen Salary • Admin Password':'Approve & Lock Salary')),
          if(row!=null&&StaffPayroll.paid(row)<StaffPayroll.total(row))const PopupMenuItem(value:'pay',child:Text('Record payment')),
          if(row!=null&&StaffPayroll.paid(row)>0)const PopupMenuItem(value:'correct',child:Text('Modify Payment • Admin Password')),
          if(row!=null&&StaffPayroll.paid(row)>0)const PopupMenuItem(value:'reverse',child:Text('Reverse Payment • Admin Password')),
          if(row!=null)const PopupMenuItem(value:'history',child:Text('Payment history')),
        ]),
      ])),
    ]);
  }
}
