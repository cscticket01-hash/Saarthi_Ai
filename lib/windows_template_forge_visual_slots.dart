import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'windows_template_import_engine.dart';
import 'windows_template_forge_auto.dart';

/// Evidence-only analyzer for the next TemplateForge image/QR pipeline.
///
/// An OCR label alone is not a usable image slot. Only a bounded, enclosed
/// rectangular border near a role label is returned. This module NEVER
/// activates a template, removes an old portrait, or guesses missing assets.
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

  /// Return counts, not only roles: two PHOTO labels on one page are
  /// ambiguous and must not silently bind to a single student portrait.
  static Map<String,int> labelCounts(String tsv,int width,int height){
    final lines=TemplateForgeAutoMapper.parseTsv(tsv,width,height);
    final counts=<String,int>{};
    for(final line in lines){
      final label=TemplateForgeAutoMapper.normalized(
        line.map((word)=>word.text).join(' '));
      for(final entry in roleLabels.entries){
        if(entry.value.any((value)=>
          TemplateForgeAutoMapper.normalized(value)==label)){
          counts[entry.key]=(counts[entry.key]??0)+1;
        }
      }
    }
    return counts;
  }

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
    // An OCR-detected photograph must be surrounded on ALL four sides.
    // Two table columns or an open decorative box cannot authorise wiping
    // a prior student's portrait into an unrelated document.
    for(var step=1;step<=7;step++){
      final y=t+((b-t)*step/8).round();
      if(!_darkNear(raster,l,y)||!_darkNear(raster,r,y))return false;
      final x=l+((r-l)*step/8).round();
      var top=false,bottom=false;
      for(var d=-2;d<=2;d++){
        if(_dark(raster,x,t+d))top=true;
        if(_dark(raster,x,b+d))bottom=true;
      }
      if(!top||!bottom)return false;
    }
    return true;
  }

  /// A conservative safety alarm for an old, *unlabelled* colour photo.
  /// OCR captions alone cannot find a sample student's face. A broad and
  /// saturated block without a verified replacement slot must not silently
  /// become part of the next student's background. This does NOT claim to
  /// detect grayscale portraits, borderless QR codes or every image design.
  ///
  /// Small logos, narrow colour banners and isolated printed highlights are
  /// intentionally excluded; only sustained multi-hue blocks trigger.
  static bool hasUnverifiedColorPhoto(
    SchoolTemplateDraft draft,List<ForgeVisualSlot> verified,
  ){
    final raster=img.decodePng(draft.png);
    if(raster==null)return false;
    const columns=40,rows=56;
    final colorful=List<int>.filled(columns*rows,0);
    final hues=List<int>.filled(columns*rows,0);
    for(var y=0;y<rows;y++){
      for(var x=0;x<columns;x++){
        final px=math.min(raster.width-1,
          ((x+.5)*raster.width/columns).floor());
        final py=math.min(raster.height-1,
          ((y+.5)*raster.height/rows).floor());
        final c=raster.getPixel(px,py);
        final r=c.r.toDouble(),g=c.g.toDouble(),b=c.b.toDouble();
        final maximum=math.max(r,math.max(g,b));
        final minimum=math.min(r,math.min(g,b));
        final index=y*columns+x;
        if(maximum-minimum>=55 && r+g+b>110 &&
            r+g+b<700){
          colorful[index]=1;
          hues[index]=r>=g&&r>=b?1:g>=b?2:3;
        }
      }
    }
    // Sliding sample windows are 12.5% of the page wide and about 12.5%
    // high. This is bounded to under 2,000 windows even for a 12 MP source.
    const boxW=5,boxH=7;
    // Check the *entire* printable sheet. Old pictures may sit near the
    // bottom of Legal/A4 marksheets, not only in the upper portrait area.
    for(var y=1;y<rows-boxH;y++){
      for(var x=1;x<=columns-boxW-1;x++){
        var filled=0,distinct=0;
        for(var v=0;v<boxH;v++){
          for(var u=0;u<boxW;u++){
            final index=(y+v)*columns+x+u;
            if(colorful[index]==1){
              filled++;
              distinct|=1<<hues[index];
            }
          }
        }
        if(filled<28 || distinct!=14)continue;
        final cx=(x+boxW/2)/columns,cy=(y+boxH/2)/rows;
        final covered=verified.any((s)=>
          cx>=s.x && cx<=s.x+s.width &&
          cy>=s.y && cy<=s.y+s.height);
        if(!covered)return true;
      }
    }
    return false;
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
    final roleCounts=labelCounts(tsv,draft.width,draft.height);
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
      // A noisy photo or dense form may produce thousands of apparent
      // horizontal edges. Never run an unbounded quadratic search.
      if(edges.length>400)continue;
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
          final labelL=labelLeft*w,labelR=labelRight*w;
          final labelT=labelTop*h,labelB=labelBottom*h;
          final inside=labelL>=l-3 && labelR<=r+3 &&
            labelT>=first.y-3 && labelB<=second.y+3;
          // Many printed school designs put PHOTO / SIGNATURE just
          // under or over the actual image frame. Only accept a nearby
          // caption aligned to the same frame, never a distant table label.
          final aligned=labelR>=l && labelL<=r;
          final below=aligned && labelT>=second.y &&
            labelT-second.y<=h*.035;
          final above=aligned && labelB<=first.y &&
            first.y-labelB<=h*.035;
          if(!inside&&!below&&!above)continue;
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
