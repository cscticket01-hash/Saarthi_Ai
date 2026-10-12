/// Core identity fields must never be erased by cache/default values.
const schoolProfileCoreFields = [
  'schoolName',
  'principalName',
  'schoolContactNo',
];
bool blankSchoolProfile(Map data) => schoolProfileCoreFields.every(
  (key) => data[key] == null || data[key].toString().trim().isEmpty,
);

class BlankSchoolProfile implements Exception {
  const BlankSchoolProfile();
  @override
  String toString() =>
      'School profile has no core identity fields. Pending data retained.';
}

void requireSchoolProfile(Map data) {
  if (blankSchoolProfile(data)) throw const BlankSchoolProfile();
}

Map<String, dynamic> mergeSchoolProfileSafely(
  Map<String, dynamic> previous,
  Map<String, dynamic> incoming,
) => {
  ...previous,
  ...incoming,
  for (final key in schoolProfileCoreFields)
    if ((incoming[key] == null || incoming[key].toString().trim().isEmpty) &&
        previous[key] != null &&
        previous[key].toString().trim().isNotEmpty)
      key: previous[key],
};
