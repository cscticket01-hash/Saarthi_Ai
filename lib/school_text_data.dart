/// Media stays in the school's local storage and Google Drive, never Firestore.
/// This also applies to nested maps received from the Google sync snapshot.
const schoolMediaFields = <String>{
  'photoUrl', 'photoBase64', 'photoMimeType', 'idCardUrl',
  'logoUrl', 'logoFileId', 'logoBase64', 'logoMimeType', 'logoFileName',
  'sealUrl', 'sealFileId', 'sealBase64', 'sealMimeType', 'sealFileName',
  'principalSignatureUrl', 'principalSignatureFileId',
  'principalSignatureBase64', 'principalSignatureMimeType',
  'principalSignatureFileName', 'schoolLogoUrl', 'schoolSealUrl',
  'reportCardUrl', 'reportCardFileId', 'receiptPdfUrl', 'pdfBase64',
  'fileUrl', 'fileId', 'fileBase64', 'downloadUrl', 'driveUrl', 'sheetUrl',
};

Map<String, dynamic> schoolTextData(Map<String, dynamic> data) => {
  for (final entry in data.entries)
    if (!schoolMediaFields.contains(entry.key))
      entry.key: _textValue(entry.value),
};

dynamic _textValue(dynamic value) {
  if (value is Map) {
    return schoolTextData(Map<String, dynamic>.from(value));
  }
  if (value is List) return value.map(_textValue).toList();
  return value;
}
