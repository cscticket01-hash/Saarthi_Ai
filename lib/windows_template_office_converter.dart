import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Offline conversion only. The existing PDF/A4 OCR pipeline is still the
/// single authoritative template importer and print renderer.
enum SchoolOfficeKind { word, spreadsheet }

class SchoolTemplateOfficeConverter {
  static const maxSourceBytes=16*1024*1024;
  static const maxConvertedPdfBytes=16*1024*1024;
  static const maxExtractedOfficeBytes=80*1024*1024;
  static const maxZipEntries=2000;

  static String extension(String name)=>
    name.contains('.')?name.split('.').last.toLowerCase():'';

  static bool supports(String name)=>const {'doc','docx','xls','xlsx'}
    .contains(extension(name));

  static SchoolOfficeKind kindFor(String name)=>switch(extension(name)){
    'doc'||'docx'=>SchoolOfficeKind.word,
    'xls'||'xlsx'=>SchoolOfficeKind.spreadsheet,
    _=>throw const FormatException(
      'Only Word DOC/DOCX and Excel XLS/XLSX are supported.'),
  };

  static bool _legacySignature(Uint8List bytes){
    const magic=[0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1];
    if(bytes.length<magic.length)return false;
    for(var i=0;i<magic.length;i++){
      if(bytes[i]!=magic[i])return false;
    }
    return true;
  }

  /// Inspect ZIP central-directory metadata without decompressing a
  /// potentially malicious zip bomb. Macro/external-link packages fail closed.
  static Set<String> _officeZipEntries(Uint8List bytes){
    if(bytes.length<22 || bytes[0]!=0x50 || bytes[1]!=0x4b ||
      bytes[2]!=3 || bytes[3]!=4){
      throw const FormatException('Office OpenXML ZIP signature is invalid.');
    }
    final data=ByteData.sublistView(bytes);
    int u16(int x)=>data.getUint16(x,Endian.little);
    int u32(int x)=>data.getUint32(x,Endian.little);
    var eocd=-1;
    final min=(bytes.length-65557).clamp(0,bytes.length);
    for(var at=bytes.length-22;at>=min;at--){
      if(u32(at)==0x06054b50 &&
        at+22+u16(at+20)==bytes.length){
        eocd=at;
        break;
      }
    }
    if(eocd<0 || u16(eocd+4)!=0 || u16(eocd+6)!=0){
      throw const FormatException('Unsupported Office ZIP layout.');
    }
    final entries=u16(eocd+10);
    final size=u32(eocd+12);
    final offset=u32(eocd+16);
    if(entries==0 || entries>maxZipEntries ||
      entries!=u16(eocd+8) || size==0 ||
      size==0xffffffff || offset==0xffffffff ||
      offset+size>eocd){
      throw const FormatException('Office ZIP directory is unsafe.');
    }
    final names=<String>{};
    var cursor=offset,expanded=0;
    for(var i=0;i<entries;i++){
      if(cursor+46>offset+size || u32(cursor)!=0x02014b50){
        throw const FormatException('Broken Office ZIP directory.');
      }
      final flags=u16(cursor+8);
      final packed=u32(cursor+20),unpacked=u32(cursor+24);
      final nameSize=u16(cursor+28);
      final extra=u16(cursor+30),comment=u16(cursor+32);
      final disk=u16(cursor+34);
      final end=cursor+46+nameSize+extra+comment;
      if((flags&1)!=0 || disk!=0 || packed==0xffffffff ||
        unpacked==0xffffffff || end>offset+size ||
        unpacked>maxExtractedOfficeBytes ||
        (packed>0 && unpacked>packed*500)){
        throw const FormatException('Unsafe compressed Office content.');
      }
      expanded+=unpacked;
      if(expanded>maxExtractedOfficeBytes){
        throw const FormatException('Office package expands beyond safe size.');
      }
      final name=utf8.decode(bytes.sublist(cursor+46,cursor+46+nameSize));
      if(name.startsWith('/') || name.contains('\\') ||
        name.split('/').contains('..') || name.contains('\u0000')){
        throw const FormatException('Invalid Office ZIP entry path.');
      }
      if(!names.add(name)){
        throw const FormatException('Duplicate Office package entry.');
      }
      final lower=name.toLowerCase();
      if(lower.endsWith('vbaproject.bin') ||
         lower.startsWith('xl/externallinks/') ||
         lower.contains('/activex/')){
        throw const FormatException(
          'Remove embedded macros or external connections before importing.');
      }
      cursor=end;
    }
    if(cursor!=offset+size){
      throw const FormatException('Office ZIP directory does not match.');
    }
    return names;
  }

  static SchoolOfficeKind validateSource(String filename,Uint8List bytes){
    if(filename.isEmpty || filename.length>180 ||
      filename.contains('/') || filename.contains('\\')){
      throw const FormatException('Invalid Office filename.');
    }
    if(bytes.isEmpty || bytes.length>maxSourceBytes){
      throw const FormatException('Office file must be under 16 MB.');
    }
    final ext=extension(filename);
    final kind=kindFor(filename);
    if(ext=='doc' || ext=='xls'){
      if(!_legacySignature(bytes)){
        throw const FormatException('File is not a genuine legacy Office file.');
      }
    }else{
      final names=_officeZipEntries(bytes);
      if(!names.contains('[Content_Types].xml') ||
        !(ext=='docx' ?names.contains('word/document.xml')
          :names.contains('xl/workbook.xml'))){
        throw const FormatException(
          'Word or Excel package does not match its extension.');
      }
    }
    return kind;
  }

  static bool isPdf(Uint8List bytes)=>
    bytes.length>=5 && bytes[0]==37 && bytes[1]==80 &&
    bytes[2]==68 && bytes[3]==70 && bytes[4]==45;

  static Future<bool> _run(
    String executable,List<String> arguments,{
    required String workingDirectory,
  }) async {
    Process process;
    try{
      process=await Process.start(executable,arguments,
        workingDirectory:workingDirectory,runInShell:false);
    }on ProcessException{
      return false;
    }
    // Drain both pipes concurrently to prevent blocking on child output.
    final out=process.stdout.drain<void>();
    final err=process.stderr.drain<void>();
    final code=await process.exitCode.timeout(
      const Duration(seconds:45),onTimeout:(){
        process.kill();
        return -1;
      });
    await Future.wait([out,err]);
    return code==0;
  }

  static List<String> _libreOfficeExecutables(){
    if(!Platform.isWindows)return ['libreoffice','soffice'];
    final env=Platform.environment;
    return [
      if(env['ProgramFiles']!=null)
        env['ProgramFiles']!+r'\LibreOffice\program\soffice.exe',
      if(env['ProgramFiles(x86)']!=null)
        env['ProgramFiles(x86)']!+r'\LibreOffice\program\soffice.exe',
      'soffice.exe',
    ];
  }

  /// Local Microsoft Office is used only when LibreOffice is unavailable.
  /// Macros are disabled and sources are opened read-only without link updates.
  static const _windowsOfficeScript=r'''
param(
  [Parameter(Mandatory=$true)][string]$InputFile,
  [Parameter(Mandatory=$true)][string]$OutputFile,
  [Parameter(Mandatory=$true)][ValidateSet('word','spreadsheet')][string]$Kind
)
$ErrorActionPreference = 'Stop'
$app = $null
$document = $null
try {
  if($Kind -eq 'word') {
    $app = New-Object -ComObject Word.Application
    $app.Visible = $false
    $app.DisplayAlerts = 0
    $app.AutomationSecurity = 3
    $app.Options.UpdateLinksAtOpen = $false
    $document = $app.Documents.Open($InputFile, $false, $true)
    $document.ExportAsFixedFormat($OutputFile, 17)
  } else {
    $app = New-Object -ComObject Excel.Application
    $app.Visible = $false
    $app.DisplayAlerts = $false
    $app.AutomationSecurity = 3
    $app.AskToUpdateLinks = $false
    $document = $app.Workbooks.Open($InputFile, 0, $true)
    $document.ExportAsFixedFormat(0, $OutputFile)
  }
  if(!(Test-Path -LiteralPath $OutputFile)){exit 7}
  exit 0
} catch {
  exit 8
} finally {
  try{
    if($null -ne $document){$document.Close($false)}
  }catch{}
  try{
    if($null -ne $app){$app.Quit()}
  }catch{}
}
''';

  /// Requires locally installed LibreOffice or the corresponding Microsoft
  /// Office desktop app. Never uploads documents to a third-party website.
  static Future<Uint8List> convert({
    required String filename,
    required Uint8List bytes,
  }) async {
    final kind=validateSource(filename,bytes);
    final ext=extension(filename);
    final root=await Directory.systemTemp.createTemp('vs-office-template-');
    try {
      final input=File(root.path+Platform.pathSeparator+'source.'+ext);
      final output=Directory(root.path+Platform.pathSeparator+'pdf');
      await output.create();
      final profile=Directory(root.path+Platform.pathSeparator+'lo-profile');
      await profile.create();
      final outputFile=File(output.path+Platform.pathSeparator+'source.pdf');
      await input.writeAsBytes(bytes,flush:true);
      bool converted=false;
      for(final executable in _libreOfficeExecutables()){
        if(executable.contains(Platform.pathSeparator) &&
           !await File(executable).exists())continue;
        final args=[
          '-env:UserInstallation='+Uri.directory(profile.path).toString(),
          '--headless','--nologo','--nodefault','--norestore',
          '--convert-to','pdf','--outdir',output.path,input.path,
        ];
        converted=await _run(executable,args,workingDirectory:root.path);
        if(converted && await outputFile.exists())break;
        converted=false;
      }
      if(!converted && Platform.isWindows){
        final script=File(root.path+Platform.pathSeparator+'convert.ps1');
        await script.writeAsString(_windowsOfficeScript,flush:true);
        converted=await _run('powershell.exe',[
          '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
          '-File',script.path,'-InputFile',input.path,
          '-OutputFile',outputFile.path,'-Kind',kind.name,
        ],workingDirectory:root.path);
      }
      if(!converted || !await outputFile.exists()){
        throw const FormatException(
          'Word/Excel conversion needs LibreOffice or Microsoft Office '
          'installed locally. Alternatively upload one A4 PDF page.');
      }
      if(await outputFile.length()>maxConvertedPdfBytes){
        throw const FormatException(
          'Converted Word/Excel PDF exceeds the 16 MB safety limit.');
      }
      final pdf=await outputFile.readAsBytes();
      if(!isPdf(pdf)){
        throw const FormatException(
          'Word/Excel conversion did not produce a genuine PDF.');
      }
      return pdf;
    }finally{
      try{await root.delete(recursive:true);}catch(_){}
    }
  }
}
