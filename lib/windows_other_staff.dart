import 'windows_person_fields.dart';
import 'windows_school_identity.dart';
import 'windows_appearance.dart';
import 'india_address_fields.dart';
import 'windows_document_templates.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'windows_local_firestore.dart';
import 'windows_school_image_cache.dart';
import 'windows_connect/school_drive_images.dart';

/// The existing payroll directory remains the single non-teacher staff source.
class OtherStaffDirectory {
  // Keep legacy role values readable without migrating historical records.
  static const roles = ['Office staff', 'Other staff'];
  static const legacyOtherRoles = ['Driver', 'Guard', 'Support staff', 'Other'];

  static String categoryFor(Map<String, dynamic> person) =>
      person['role'] == 'Office staff' ? 'Office staff' : 'Other staff';

  static String suggestedDesignation(Map<String, dynamic> person) {
    final designation = person['designation']?.toString().trim() ?? '';
    if (designation.isNotEmpty) return designation;
    final role = person['role']?.toString() ?? '';
    return legacyOtherRoles.contains(role) && role != 'Other' ? role : '';
  }
  static Future<void> _tail = Future<void>.value();
  static void requireSchool(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile)
      throw StateError('School changed. Reopen Staff Directory.');
  }

  static Future<List<Map<String, dynamic>>> load(String profile) async {
    requireSchool(profile);
    final data =
        (await FirebaseFirestore.instance
                .collection('school_settings')
                .doc('staff_payroll_directory')
                .get())
            .data();
    requireSchool(profile);
    return (data?['staff'] as List? ?? [])
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
  }

  static Future<void> save(String profile, Map<String, dynamic> person) {
    final next = _tail.then((_) async {
      requireSchool(profile);
      final name = person['name']?.toString().trim() ?? '',
          employee = person['employeeId']?.toString().trim() ?? '';
      if (name.isEmpty ||
          name.length > 120 ||
          employee.isEmpty ||
          employee.length > 60 ||
          !(roles.contains(person['role']) ||
              legacyOtherRoles.contains(person['role'])))
        throw ArgumentError(
          'Name, unique Employee ID and staff category are required.',
        );
      final designation = person['designation']?.toString().trim() ?? '';
      if (categoryFor(person) == 'Other staff' && designation.isEmpty) {
        throw ArgumentError('Enter a designation for Other Staff.');
      }
      final directoryRef = FirebaseFirestore.instance.collection('school_settings').doc('staff_payroll_directory');
      final originalDirectory = (await directoryRef.get()).data();
      final people = (originalDirectory?['staff'] as List? ?? []).whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s)).toList();
      final teachers = await FirebaseFirestore.instance
          .collection('teachers_directory')
          .get();
      requireSchool(profile);
      if (people.any(
            (p) =>
                p['id'] != person['id'] &&
                p['employeeId']?.toString().toLowerCase() ==
                    employee.toLowerCase(),
          ) ||
          teachers.docs.any(
            (d) =>
                (d.data()['teacherId'] ?? d.id).toString().toLowerCase() ==
                employee.toLowerCase(),
          ))
        throw StateError('This Employee ID is already assigned.');
      final id =
          person['id']?.toString() ??
          'staff:${SchoolPersonIdentity.newGeneration()}';
      final index = people.indexWhere((p) => p['id'] == id);
      final previous = index < 0 ? null : people[index];
      if (previous != null && (previous['employeeId']?.toString().trim() ?? '').isNotEmpty &&
          previous['employeeId'] != employee) {
        throw StateError('Existing Employee ID is permanent. Retain the original payroll identity.');
      }
      final record = {
        ...?previous,
        ...person,
        if (previous?['mobileStableId'] != null) 'mobileStableId': previous!['mobileStableId']
        else if (index < 0) 'mobileStableId': SchoolPersonIdentity.newGeneration(),
        'id': id,
        'name': name,
        'employeeId': employee,
        'designation': designation,
        'active': person['active'] != false,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      if (index < 0)
        people.add(record);
      else
        people[index] = record;
      requireSchool(profile);
      final batch = FirebaseFirestore.instance.batch();
      batch.requireUnchanged(directoryRef, originalDirectory);
      batch.set(directoryRef, {'staff': people}, SetOptions(merge: true));
      await batch.commit();
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
}

class SchoolStaffDirectory extends StatefulWidget {
  const SchoolStaffDirectory({super.key, required this.teachers});
  final Widget teachers;
  @override
  State<SchoolStaffDirectory> createState() => _SchoolStaffDirectoryState();
}

class _SchoolStaffDirectoryState extends State<SchoolStaffDirectory> {
  late final String profile;
  String category = 'Teachers', search = '';
  List<Map<String, dynamic>> staff = [];
  String? error;
  @override
  void initState() {
    super.initState();
    profile = FirebaseFirestore.instance.activeProfileId;
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await OtherStaffDirectory.load(profile);
      if (mounted)
        setState(() {
          staff = value;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _idCard(Map<String, dynamic> person) async {
    try {
      OtherStaffDirectory.requireSchool(profile);
      if (!mounted) return;
      await WindowsDocumentTemplates.previewNativePerson(context,'otherStaffId', {
        ...person,
        'contact': person['mobile'] ?? '',
        'rollNo': person['employeeId'] ?? '',
      },filename:'staff-id.pdf');
      OtherStaffDirectory.requireSchool(profile);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final name = TextEditingController(
          text: existing?['name']?.toString() ?? '',
        ),
        employee = TextEditingController(
          text: existing?['employeeId']?.toString() ?? '',
        ),
        department = TextEditingController(
          text: existing == null
              ? ''
              : OtherStaffDirectory.suggestedDesignation(existing),
        ),
        mobile = TextEditingController(
          text: existing?['mobile']?.toString() ?? '',
        ),
        joining = TextEditingController(
          text: existing?['joiningDate']?.toString() ?? '',
        );
    final birth = TextEditingController(text: existing?['dateOfBirth']?.toString() ?? '');
    final address = TextEditingController(text: existing?['address']?.toString() ?? '');
    final country = TextEditingController(text: existing?['country']?.toString().trim().isNotEmpty == true ? existing!['country'].toString() : 'India');
    final state = TextEditingController(text: existing?['state']?.toString() ?? '');
    final district = TextEditingController(text: existing?['district']?.toString() ?? '');
    var role = existing?['role']?.toString() ?? category,
        active = existing?['active'] != false;
    if (!OtherStaffDirectory.roles.contains(role) &&
        !OtherStaffDirectory.legacyOtherRoles.contains(role)) {
      role = 'Other staff';
    }
    var photo = existing?['photoUrl']?.toString() ?? '', saving = false;
    String? problem;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => PopScope(
          canPop: !saving,
          child: AlertDialog(
            title: Text(
              existing == null
                  ? 'Add ${OtherStaffDirectory.categoryFor({'role': role})}'
                  : 'Edit ${OtherStaffDirectory.categoryFor({'role': role})}',
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    TextField(
                      controller: employee,
                      decoration: const InputDecoration(
                        labelText: 'Employee ID',
                      ),
                    ),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Category'),
                      child: Text(OtherStaffDirectory.categoryFor({'role': role})),
                    ),
                    TextField(
                      controller: department,
                      decoration: const InputDecoration(
                        labelText: 'Designation (enter manually)',
                      ),
                    ),
                    TextField(
                      controller: mobile,
                      decoration: const InputDecoration(labelText: 'Mobile'),
                    ),
                    WindowsDateOfBirthField(controller: birth, enabled: !saving),
                    TextField(
                      controller: joining,
                      decoration: const InputDecoration(
                        labelText: 'Joining date / details',
                      ),
                    ),
                    TextField(controller: address, decoration: const InputDecoration(labelText: 'Address')),
                    const SizedBox(height: 10),
                    IndiaAddressFields(country: country, state: state, district: district, enabled: !saving),
                    SwitchListTile(
                      value: active,
                      onChanged: saving ? null : (v) => setD(() => active = v),
                      title: const Text('Active'),
                    ),
                    if (photo.isNotEmpty)
                      schoolNetworkImage(
                        photo,
                        width: 70,
                        height: 70,
                        fit: BoxFit.cover,
                      ),
                    TextButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              try {
                                final file = await ImagePicker().pickImage(
                                  source: ImageSource.gallery,
                                  maxWidth: 600,
                                  imageQuality: 80,
                                );
                                if (file == null) return;
                                final bytes = await file.readAsBytes();
                                OtherStaffDirectory.requireSchool(profile);
                                if (bytes.length > 5 * 1024 * 1024)
                                  throw StateError(
                                    'Select a photo smaller than 5 MB.',
                                  );
                                if (ctx.mounted)
                                  setD(
                                    () => photo =
                                        WindowsSchoolImageCache.dataUrl(bytes),
                                  );
                              } catch (e) {
                                if (ctx.mounted) setD(() => problem = '$e');
                              }
                            },
                      icon: const Icon(Icons.photo),
                      label: const Text('Select photo'),
                    ),
                    if (problem != null)
                      Text(
                        problem!,
                        style: TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.orangeAccent)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        setD(() => saving = true);
                        try {
                          await OtherStaffDirectory.save(profile, {
                            ...?existing,
                            'name': name.text,
                            'employeeId': employee.text,
                            'role': role,
                            'designation': department.text,
                            'mobile': mobile.text,
                            'joiningDate': joining.text,
                            'dateOfBirth': birth.text.trim(),
                            'address': address.text.trim(),
                            'country': country.text.trim(),
                            'state': state.text.trim(),
                            'district': district.text.trim(),
                            'active': active,
                            'photoUrl': photo,
                          });
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (ctx.mounted)
                            setD(() {
                              saving = false;
                              problem = '$e';
                            });
                        }
                      },
                child: Text(saving ? 'Saving…' : 'Save locally'),
              ),
            ],
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final c in [name, employee, department, mobile, joining, birth, address, country, state, district]) c.dispose();
    if (changed == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Teachers & Other Staff')),
    body: Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final r in ['Teachers', ...OtherStaffDirectory.roles])
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: ChoiceChip(
                    label: Text(r),
                    selected: category == r,
                    onSelected: (_) => setState(() => category = r),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: category == 'Teachers'
              ? widget.teachers
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              onChanged: (v) =>
                                  setState(() => search = v.toLowerCase()),
                              decoration: const InputDecoration(
                                labelText: 'Search staff name / Employee ID',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: () => _edit(),
                            icon: const Icon(Icons.person_add),
                            label: Text(category == 'Office staff'
                                ? 'Add Office Staff'
                                : 'Add Other Staff'),
                          ),
                        ],
                      ),
                    ),
                    if (error != null) Text(error!),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final person in staff.where(
                            (p) =>
                                OtherStaffDirectory.categoryFor(p) == category &&
                                '${p['name']} ${p['employeeId']} ${OtherStaffDirectory.suggestedDesignation(p)}'
                                    .toLowerCase()
                                    .contains(search),
                          ))
                            ListTile(
                              leading:
                                  (person['photoUrl']?.toString().isNotEmpty ??
                                      false)
                                  ? schoolNetworkImage(
                                      person['photoUrl'],
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                    )
                                  : const Icon(Icons.person),
                              title: Text(person['name']?.toString() ?? ''),
                              subtitle: Text(
                                '${person['employeeId'] ?? person['id']} • ${person['designation'] ?? ''} • ${person['active'] == false ? 'Inactive' : 'Active'}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'ID front + back',
                                    onPressed: () => _idCard(person),
                                    icon: const Icon(Icons.badge_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Edit staff',
                                    onPressed: () => _edit(person),
                                    icon: const Icon(Icons.edit),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    ),
  );
}
