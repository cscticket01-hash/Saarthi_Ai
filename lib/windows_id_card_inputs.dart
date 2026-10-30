/// The same effective person values used by automatic ID rendering.
Map<String,dynamic> personCardData(Map person,Map profile) => {
  ...Map<String,dynamic>.from(person),
  'schoolName':profile['schoolName']??profile['name']??'',
  'roll':person['rollNo'],'contact':person['parentContact'],
  'streetAddress':person['address'],
  'address':[person['address'],person['district'],person['state']]
    .where((v)=>v!=null&&v.toString().isNotEmpty).join(', '),
  'showStudentUid':person['studentUid']!=null,
};

/// Fixed reference teacher layouts. Only values actually printed by the chosen
/// design belong to its input identity; salary, login and sync metadata do not.
Map<String,String> teacherCardText(Map data,int design) {
  String first(List<String> keys,[String fallback='-']) {
    for(final key in keys){final value=data[key]?.toString().trim()??'';
      if(value.isNotEmpty&&value!='null')return value;}
    return fallback;
  }
  return {
    'school':first(['schoolName','nameOfSchool'],'School name'),
    'name':first(['name','teacherName'],'Teacher name'),
    if(design<3)...{
      'father':first(['fatherName','parentName']),
      'dob':first(['dateOfBirth','dob']),
      'subject':first(['subject','department']),
      'address':first(['address']),
      'schoolAddress':first(['schoolAddress','address']),
      'schoolEmail':first(['schoolEmail','email']),
      'schoolContact':first(['schoolContactNo','contact','phone']),
    },
    if(design==2)'designation':first(['designation'],'Teacher'),
    if(design==3)...{
      'designation':first(['designation'],'TEACHER'),'subject':first(['subject']),
      'contact':first(['contact','phone']),'email':first(['email']),
      'website':first(['schoolWebsite','website']),'address':first(['address']),
      'bloodGroup':first(['bloodGroup']),
      'emergencyContact':first(['emergencyContact','contact','phone']),
    },
    'terms':first(['idCardTerms'],design<2
      ?'This card identifies a member of the school staff. Carry it while on duty. Return it to the school office if found. This card is not transferable.'
      :design==2?'Carry this school ID while on duty. If found, return it to the school office. It is not transferable.':'This card is the property of the school and identifies its staff member. Wear it while on duty. It is not transferable. If found, return it to the school office.'),
  };
}
