import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'windows_template_import_engine.dart';
import 'windows_template_forge_auto.dart';

/// Evidence-only analyzer for the next TemplateForge image/QR pipeline.
///
/// An OCR label alone is not a usable image slot. Only a bounded, enclosed
/// rectangular border near a role label is returned. This module NEVER
/// activates a template, removes an old portrait, or guesses missing assets.
class ForgeVisualSlot {
  const ForgeVisualSlot({
    required this.role,required this.x,required this.y,
    required this.width,required this.height,
  });
  final String role;
  final double x,y,width,height;
}

class TemplateForgeVisualSlots {
  static const roleLabels=<String,List<String>>{
    'studentPhoto':['student photo','passport photo','photo','photograph',
      'फोटो','छात्र फोटो','শিক্ষার্থীর ছবি','ছাত্ৰৰ ফটো'],
    'schoolLogo':['school logo','institution logo','logo','বিদ্যালয়ের লোগো',
      'विद्यालय लोगो'],
    'signature':['principal signature','authorised signature',
      'authorized signature','signature','हस्ताक्षर','স্বাক্ষর','স্বাক্ষৰ'],
    'seal':['school seal','school stamp','seal','stamp','मुहर','সিল'],
    'qrCode':['qr code','qr','scan qr','কিউআর','क्यूआर'],
  };

  static bool _dark(img.Image raster,int x,int y){
    if(x<0||y<0||x>=raster.width||y>=raster.height)return false;
    final p=raster.getPixel(x,y);
    return (p.r+p.g+p.b)<315;
  }

  static bool _darkNear(img.Image raster,int x,int y){
    for(var d=-2;d<=2;d++){
      if(_dark(raster,x+d,y))return true;
    }
    return false;
  }

  static bool _closedBorder(img.Image raster,int l,int t,int r,int b){
    for(var step=1;step<=7;step++){
      final y=t+((b-t)*step/8).round();
      if(!_darkNear(raster,l,y)||!_darkNear(raster,r,y))return false;
    }
    return true;
  }

  /// Bounded scan near an OCR role label. Strongly rotated, decorative or
  /// borderless placeholders remain unresolved instead of being fabricated.
  static List<ForgeVisualSlot> detect(
    SchoolTemplateDraft draft,String tsv,
  ){
    final lines=TemplateForgeAutoMapper.parseTsv(
      tsv,draft.width,draft.height);
    final raster=img.decodePng(draft.png);
    if(raster==null)return const [];
    final w=raster.width,h=raster.height;
    final results=<ForgeVisualSlot>[];
    final roleCounts=<String,int>{};
    for(final line in lines){
      final label=TemplateForgeAutoMapper.normalized(
        line.map((word)=>word.text).join(' '));
      for(final entry in roleLabels.entries){
        if(entry.value.any((value)=>
          TemplateForgeAutoMapper.normalized(value)==label)){
          roleCounts[entry.key]=(roleCounts[entry.key]??0)+1;
        }
      }
    }
    for(final line in lines){
      final label=TemplateForgeAutoMapper.normalized(
        line.map((word)=>word.text).join(' '));
      final matching=roleLabels.entries.where((entry)=>entry.value.any(
        (phrase)=>TemplateForgeAutoMapper.normalized(phrase)==label)).toList();
      if(matching.length!=1)continue;
      final key=matching.single.key;
      if(roleCounts[key]!=1 || results.any((r)=>r.role==key))continue;
      final labelLeft=line.map((v)=>v.x).reduce(math.min);
      final labelRight=line.map((v)=>v.x+v.w).reduce(math.max);
      final labelTop=line.map((v)=>v.y).reduce(math.min);
      final labelBottom=line.map((v)=>v.y+v.h).reduce(math.max);
      final left=math.max(0,((labelLeft-.24)*w).floor());
      final right=math.min(w-1,((labelRight+.24)*w).ceil());
      final top=math.max(0,((labelTop-.20)*h).floor());
      final bottom=math.min(h-1,((labelBottom+.25)*h).ceil());
      final minLine=(w*.07).ceil();
      final maxLine=(w*.42).floor();
      final edges=<({int l,int r,int y})>[];
      // Sample at most about 900 horizontal rows per label.
      final stride=math.max(1,(bottom-top)~/900);
      for(var y=top;y<=bottom;y+=stride){
        var start=-1;
        for(var x=left;x<=right+1;x++){
          final dark=x<=right && _dark(raster,x,y);
          if(dark && start<0)start=x;
          if(!dark && start>=0){
            final length=x-start;
            if(length>=minLine && length<=maxLine){
              edges.add((l:start,r:x-1,y:y));
            }
            start=-1;
          }
        }
      }
      final found=<ForgeVisualSlot>[];
      for(var i=0;i<edges.length;i++){
        final first=edges[i];
        for(var j=i+1;j<edges.length;j++){
          final second=edges[j];
          final height=second.y-first.y;
          if(height<(h*.055).ceil()||height>(h*.38).floor())continue;
          if((first.l-second.l).abs()>w*.009 ||
             (first.r-second.r).abs()>w*.009)continue;
          final l=math.min(first.l,second.l),
              r=math.max(first.r,second.r);
          if(labelLeft*w<l-3||labelRight*w>r+3 ||
             labelTop*h<first.y-3||labelBottom*h>second.y+3){
            continue;
          }
          if(!_closedBorder(raster,l,first.y,r,second.y))continue;
          final candidate=ForgeVisualSlot(
            role:key,x:l/w,y:first.y/h,
            width:(r-l)/w,height:height/h);
          if(!found.any((other)=>
            (other.x-candidate.x).abs()<.012 &&
            (other.y-candidate.y).abs()<.012 &&
            (other.width-candidate.width).abs()<.012 &&
            (other.height-candidate.height).abs()<.012)){
            found.add(candidate);
          }
        }
      }
      // Two plausible boxes around one label are ambiguous. A wrongly
      // selected old portrait/QR is worse than asking for a cleaner scan.
      if(found.length==1)results.add(found.single);
    }
    return results;
  }
}
