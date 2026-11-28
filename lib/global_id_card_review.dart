import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' as zx;
import 'id_card_manifest.dart';

/// Review-only raster cleanup and bounded approximation. It never edits original
/// source bytes and cannot recover original artwork hidden by opaque samples.
class GlobalIdCardReview {
  static const imageFields={'photo','logo','signature','seal'};
  static const textFields={'schoolName','schoolAddress','schoolLocation','schoolEmail','schoolContactNo','name','parentName','dob','class','section','rollNo','designation','subject','contact','address','pinCode','district','state','country','session','employeeId','bloodGroup','emergencyContact','academicSession','confirmedUniversalStudentUid'};
  static String kind(String key)=>imageFields.contains(key)?'image':key=='qr'?'qr':'text';
  /// Shared detection path for the read-only tracker and review editor.
  static List<Map<String,dynamic>> detectSlots(List<Map<String,dynamic>> pages,Map<String,Uint8List> images){
    final slots=<Map<String,dynamic>>[];
    Map<String,dynamic> withMask(Map<String,dynamic> row)=>{...row,for(final k in ['x','y','width','height'])'sample_$k':row['sample_$k']??row[k]};
    for(final page in pages){
      for(final item in (page['candidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        if(textFields.contains(r['key']))slots.add(withMask(r));
      }
      for(final item in (page['imageCandidates'] as List? ?? const [])){
        final r=Map<String,dynamic>.from(item as Map);
        final role=r['suggestedRole'];
        final recognized=(imageFields.contains(role)||role=='qr')&&!slots.any((s)=>s['side']==r['side']&&s['key']==role);
        slots.add(withMask({...r,'key':recognized?role:''}));
      }
    }
    suggestQr(pages,slots,images);
    refineImageRoles(pages,slots,images);
    refinePortraitBounds(pages,slots,images);
    suggestPlaceholderSlots(pages,slots,images);
    return slots;
  }
  // Geometry is expressed in the same design units used by IdCardLayout.
  // Do not lower the 6-unit font minimum or change the sample-removal mask.
  static const double minimumTextHeight=7.5;
  static double _n(Map<String,dynamic> r,String k)=>(r[k] as num?)?.toDouble()??0;
  static double _minimumTextWidth(Map<String,dynamic> r){
    // Short sample values (X, 02) are not adequate output regions.
    // These are conservative geometry hints; the actual renderer is final.
    switch(r['key']){
      case 'class':case 'rollNo':case 'section':return 13;
      case 'confirmedUniversalStudentUid':return 30;
      case 'name':case 'parentName':case 'contact':case 'dob':return 24;
      default:return 6;
    }
  }
  static String? readabilityIssue(Map<String,dynamic> r){
    if(!textFields.contains(r['key']))return null;
    final vertical=r['rotation']==-90;
    final h=_n(r,vertical?'width':'height'),w=_n(r,vertical?'height':'width');
    if(h<minimumTextHeight||w<6){
      return '${r['key']} (${r['side']}): output text area ${w.toStringAsFixed(1)} × ${h.toStringAsFixed(1)}; needs at least 6 × 7.5 design units. Resize the output field; retain the original sample mask.';
    }
    return null;
  }
  /// Suggest a small bounded expansion around the existing text area.
  /// Other dynamic/static candidate regions and page edges are obstacles.
  /// No source pixels are changed; any expansion must be visually reviewed.
  static List<Map<String,dynamic>> fitOutputRegions(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> input){
    final result=input.map((r)=>Map<String,dynamic>.from(r)).toList();
    for(final r in result){
      if(!textFields.contains(r['key']))continue;
      final rotated=r['rotation']==-90;
      if(readabilityIssue(r)==null&&_n(r,rotated?'height':'width')>=_minimumTextWidth(r))continue;
      final page=pages.where((p)=>p['side']==r['side']).firstOrNull;
      if(page==null)continue;
      final pw=_n(page,'canvasWidth'),ph=_n(page,'canvasHeight');
      final x=_n(r,'x'),y=_n(r,'y'),w=_n(r,'width'),h=_n(r,'height');
      if(![pw,ph,x,y,w,h].every((v)=>v.isFinite)||x<0||y<0||w<=0||h<=0||x+w>pw||y+h>ph)continue;
      final vertical=r['rotation']==-90;
      final targetW=math.max(w,vertical?7.6:_minimumTextWidth(r)+.1);
      final targetH=math.max(h,vertical?_minimumTextWidth(r)+.1:7.6);
      // Only modest automatic expansion; larger corrections need a person.
      if(targetW-w>(vertical?5:24)||targetH-h>(vertical?24:5))continue;
      final dw=targetW-w,dh=targetH-h;
      final preferredX=vertical?x-dw/2:r['align']=='right'?x-dw:r['align']=='center'?x-dw/2:x;
      final preferredY=vertical?y+ h-targetH:y-dh/2;
      bool free(double xx,double yy){
        if(xx<0||yy<0||xx+targetW>pw||yy+targetH>ph)return false;
        for(final other in result){
          if(identical(r,other)||other['side']!=r['side'])continue;
          final ox=_n(other,'x'),oy=_n(other,'y'),ow=_n(other,'width'),oh=_n(other,'height');
          if(xx<ox+ow&&xx+targetW>ox&&yy<oy+oh&&yy+targetH>oy)return false;
        }
        return true;
      }
      final xs=[preferredX,if(vertical)x,if(vertical)x-dw];
      final ys=[preferredY,if(!vertical)y,if(!vertical)y-dh,if(vertical)y];
      bool done=false;
      for(final xx in xs){
        for(final yy in ys){
          if(!free(xx,yy))continue;
          for(final k in ['x','y','width','height'])r['sample_'+k]??=r[k];
          r.addAll({'x':xx,'y':yy,'width':targetW,'height':targetH,'fitAdjusted':true});
          done=true;break;
        }
        if(done)break;
      }
    }
    return result;
  }
  /// Automatically prepare a draft only when mandatory fields are present and
  /// every explicitly detected placeholder has a matching slot. Ambiguous
  /// candidates stay in the correction editor. Final publication still needs
  /// independent demo rendering and human approval.
  static bool canAutoPrepare(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> slots){
    if(pages.isEmpty||slots.isEmpty||slots.any((r)=>r['key']==''||r['key']==null||r['roleConfidence']=='low'))return false;
    if(!slots.any((r)=>r['side']=='front'&&r['key']=='name')||!slots.any((r)=>r['key']=='qr'))return false;
    for(final page in pages){
      final side=page['side'];
      for(final label in (page['labelSlots'] as List? ?? const [])){
        final role=(label as Map)['role'];
        if(!slots.any((r)=>r['side']==side&&r['key']==role))return false;
      }
    }
    return true;
  }
  /// Suggest a QR role only when an actual embedded raster decodes uniquely.
  /// The decoded sample string is never retained, displayed or returned.
  static void suggestQr(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    final detected=<Map<String,dynamic>>[];
    var inspected=0;
    for(final page in pages){
      final side=page['side'],bytes=rasters[side];
      if(bytes==null||bytes.length>8*1024*1024)continue;
      final source=img.decodePng(bytes);
      if(source==null||source.width*source.height>20000000)continue;
      final sx=source.width/(page['canvasWidth'] as num),sy=source.height/(page['canvasHeight'] as num);
      for(final row in slots.where((r)=>r['side']==side&&r['kind']=='image'&&r['key']!='__static')){
        if(inspected>=24)return;
        final w=(row['width'] as num).toDouble(),h=(row['height'] as num).toDouble();
        if(w<=0||h<=0||w/h<.75||w/h>1.33)continue;
        inspected++;
        final x=((row['x'] as num)*sx).floor().clamp(0,source.width-1).toInt();
        final y=((row['y'] as num)*sy).floor().clamp(0,source.height-1).toInt();
        final right=(((row['x'] as num)+w)*sx).ceil().clamp(x+1,source.width).toInt();
        final bottom=(((row['y'] as num)+h)*sy).ceil().clamp(y+1,source.height).toInt();
        if(right-x<40||bottom-y<40)continue;
        try{
          var crop=img.copyCrop(source,x:x,y:y,width:right-x,height:bottom-y);
          final long=math.max(crop.width,crop.height);
          if(long>800)crop=img.copyResize(crop,width:(crop.width*800/long).round(),height:(crop.height*800/long).round(),interpolation:img.Interpolation.nearest);
          final pixels=Int32List(crop.width*crop.height);
          for(final p in crop)pixels[p.y*crop.width+p.x]=(p.r.toInt()<<16)|(p.g.toInt()<<8)|p.b.toInt();
          final decoded=zx.QRCodeReader().decode(zx.BinaryBitmap(zx.HybridBinarizer(zx.RGBLuminanceSource(crop.width,crop.height,pixels))));
          if(decoded.text.isNotEmpty)detected.add(row);
        }catch(_){/* No reliable QR evidence; keep it unclassified. */}
      }
    }
    for(final page in pages){
      final side=page['side'];
      final matches=detected.where((r)=>r['side']==side).toList();
      if(matches.length!=1)continue;
      final actual=matches.single;
      // Pixel decoding is stronger evidence than a nearby label or geometry.
      // Preserve competing candidates as unresolved rather than discarding them.
      for(final r in slots.where((r)=>r['side']==side&&r['key']=='qr'&&!identical(r,actual))){
        r['key']='';r['roleEvidence']='conflicting_qr_candidate';
      }
      actual['key']='qr';actual['roleEvidence']='decoded_raster';actual['roleConfidence']='high';
    }
  }
  /// Non-biometric visual features: distinguish sparse horizontal ink,
  /// dense multicolour pictures and circular marks. Combine with geometry
  /// and explicit nearby labels. This never identifies a person's face.
  static String? pixelRole(img.Image image,double fraction,double centerY){
    if(image.width<8||image.height<8||fraction>.65)return null;
    final ratio=image.width/image.height;
    final crop=img.copyResize(image,width:64,height:64);
    var ink=0,colour=0,ring=0,core=0,ringTotal=0,coreTotal=0;
    final tones=<int>{};
    for(final p in crop){
      final dx=(p.x-31.5)/31.5,dy=(p.y-31.5)/31.5,d=dx*dx+dy*dy;
      final r=p.r.toInt(),g=p.g.toInt(),b=p.b.toInt();
      final isInk=math.min(r,math.min(g,b))<190&&p.a>80;
      if(isInk)ink++;
      if(math.max(r,math.max(g,b))-math.min(r,math.min(g,b))>28)colour++;
      tones.add(((r>>5)<<6)|((g>>5)<<3)|(b>>5));
      if(d>.38&&d<.90){ringTotal++;if(isInk)ring++;}
      if(d<.18){coreTotal++;if(isInk)core++;}
    }
    final density=ink/4096,chroma=colour/4096;
    if(ratio>=2.2&&centerY>.56&&fraction<.12&&density>.025&&density<.36&&chroma<.25)return 'signature';
    if(ratio>=.7&&ratio<=1.35&&centerY>.58&&fraction<.12&&ringTotal>0&&coreTotal>0&&
       ring/ringTotal>.26&&ring/ringTotal-core/coreTotal>.18)return 'seal';
    if(ratio>=.55&&ratio<=1.4&&fraction>=.065&&fraction<.36&&tones.length>45&&density>.35&&chroma>.15)return 'photo';
    if(ratio>=.65&&ratio<=2.2&&centerY<.30&&fraction<.075&&density>.06&&density<.75&&tones.length<=45)return 'logo';
    return null;
  }
  static void refineImageRoles(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    for(final page in pages){
      final side=page['side'],bytes=rasters[side];
      if(bytes==null||bytes.length>8*1024*1024)continue;
      final source=img.decodePng(bytes);
      if(source==null||source.width*source.height>20000000)continue;
      final pw=(page['canvasWidth'] as num).toDouble(),ph=(page['canvasHeight'] as num).toDouble();
      if(pw<=0||ph<=0)continue;
      final proposals=<String,List<Map<String,dynamic>>>{};
      for(final row in slots.where((r)=>r['side']==side&&r['kind']=='image'&&r['key']!='qr'&&r['key']!='__static').take(64)){
        final x=(row['x'] as num).toDouble(),y=(row['y'] as num).toDouble(),w=(row['width'] as num).toDouble(),h=(row['height'] as num).toDouble();
        if(w<=0||h<=0||x<0||y<0||x+w>pw||y+h>ph)continue;
        final l=(x/pw*source.width).floor(),t=(y/ph*source.height).floor();
        final right=((x+w)/pw*source.width).ceil().clamp(l+1,source.width).toInt();
        final bottom=((y+h)/ph*source.height).ceil().clamp(t+1,source.height).toInt();
        final role=pixelRole(img.copyCrop(source,x:l,y:t,width:right-l,height:bottom-t),w*h/(pw*ph),(y+h/2)/ph);
        if(role==null)continue;
        (proposals[role]??=[]).add(row);
      }
      for(final entry in proposals.entries){
        if(entry.value.length!=1)continue;
        final row=entry.value.single,role=entry.key;
        if(slots.any((s)=>!identical(s,row)&&s['side']==side&&s['key']==role))continue;
        final suggested=row['suggestedRole'];
        if(suggested==role){
          row['key']=role;row['roleEvidence']='geometry_and_pixel_features';row['roleConfidence']='medium';
        }else if(row['key']==''){
          row['suggestedRole']=role;row['roleEvidence']='pixel_features_only';row['roleConfidence']='low';
        }
      }
    }
  }
  /// Find actual rectangular placeholder borders near explicit Logo/QR/Photo
  /// labels. Work on a bounded raster; no made-up rectangle if edges are
  /// ambiguous. The label is the removal mask and the inset box is the output.
  /// Seek a coherent circular border inside an oversized portrait candidate.
  /// Non-biometric edge geometry only; never infer a person's identity.
  static void refinePortraitBounds(List<Map<String,dynamic>> pages,List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    for(final page in pages){
      final side=page['side'],bytes=rasters[side];
      if(bytes==null||bytes.length>8*1024*1024)continue;
      final decoded=img.decodePng(bytes);
      if(decoded==null||decoded.width*decoded.height>20000000)continue;
      final scale=math.min(1.0,480/math.max(decoded.width,decoded.height));
      final source=scale==1?decoded:img.copyResize(decoded,width:math.max(1,(decoded.width*scale).round()),height:math.max(1,(decoded.height*scale).round()));
      final sx=source.width/(page['canvasWidth'] as num),sy=source.height/(page['canvasHeight'] as num);
      for(final row in slots.where((r)=>r['side']==side&&r['key']=='photo')){
        final x=(row['x'] as num)*sx,y=(row['y'] as num)*sy,w=(row['width'] as num)*sx,h=(row['height'] as num)*sy;
        if(w<35||h<35||w/h>.92||w/h<.45)continue;
        double edge(double xx,double yy,double radius,double angle){
          final ax=(xx+(radius-1.5)*math.cos(angle)).round(),ay=(yy+(radius-1.5)*math.sin(angle)).round();
          final bx=(xx+(radius+1.5)*math.cos(angle)).round(),by=(yy+(radius+1.5)*math.sin(angle)).round();
          if([ax,bx].any((v)=>v<0||v>=source.width)||[ay,by].any((v)=>v<0||v>=source.height))return 0;
          final a=source.getPixel(ax,ay),b=source.getPixel(bx,by);
          return math.max((a.r-b.r).abs(),math.max((a.g-b.g).abs(),(a.b-b.b).abs())).toDouble();
        }
        double best=0,bx=0,by=0,br=0;
        for(var cx=x+w*.46;cx<=x+w*.54;cx+=2){
          for(var cy=y+h*.35;cy<=y+h*.68;cy+=2){
            for(var radius=w*.36;radius<=w*.5;radius+=1){
              if(cx-radius<x-1||cx+radius>x+w+1||cy-radius<y||cy+radius>y+h)continue;
              var strong=0;double total=0;
              for(var i=0;i<32;i++){
                final v=edge(cx,cy,radius,2*math.pi*i/32);
                if(v>22)strong++;
                total+=math.min(v,90);
              }
              final score=strong/32*.8+total/(32*90)*.2;
              if(strong>=23&&score>best){best=score;bx=cx;by=cy;br=radius;}
            }
          }
        }
        if(best<.65||br<=0)continue;
        final nx=(bx-br)/sx,ny=(by-br)/sy,nw=2*br/sx,nh=2*br/sy;
        // A verified border narrows only the proposed region; review remains mandatory.
        row.addAll({'x':nx,'y':ny,'width':nw,'height':nh,'sample_x':nx,'sample_y':ny,'sample_width':nw,'sample_height':nh,'oval':true,'roleEvidence':'circular_border_geometry','reviewRequired':true});
      }
    }
  }
  static void suggestPlaceholderSlots(List<Map<String,dynamic>> pages,
      List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters){
    for(final page in pages){
      final side=page['side'],bytes=rasters[side];
      if(bytes==null||bytes.length>8*1024*1024)continue;
      final decoded=img.decodePng(bytes);
      if(decoded==null||decoded.width*decoded.height>20000000)continue;
      final scale=math.min(1.0,480/math.max(decoded.width,decoded.height));
      final source=scale==1?decoded:img.copyResize(decoded,width:math.max(1,(decoded.width*scale).round()),height:math.max(1,(decoded.height*scale).round()));
      final pw=(page['canvasWidth'] as num).toDouble(),ph=(page['canvasHeight'] as num).toDouble();
      final sx=source.width/pw,sy=source.height/ph;
      double edge(int x,int y,bool vertical){
        final a=source.getPixel(x,y),b=source.getPixel(vertical?x-1:x,vertical?y:y-1);
        return math.max((a.r-b.r).abs(),math.max((a.g-b.g).abs(),(a.b-b.b).abs())).toDouble();
      }
      for(final item in (page['labelSlots'] as List? ?? const [])){
        final row=Map<String,dynamic>.from(item as Map),role=row['role'];
        if(!['logo','qr','photo'].contains(role)||slots.any((r)=>r['side']==side&&r['key']==role))continue;
        final x=(row['x'] as num).toDouble(),y=(row['y'] as num).toDouble();
        final w=(row['width'] as num).toDouble(),h=(row['height'] as num).toDouble();
        final cx=((x+w/2)*sx).round(),cy=((y+h/2)*sy).round();
        final rx=math.min((source.width*.24).round(),math.max(12,(w*sx*3).round()));
        final ry=math.min((source.height*.30).round(),math.max(12,(h*sy*6).round()));
        if(cx<2||cy<2||cx>=source.width-2||cy>=source.height-2)continue;
        final x0=math.max(2,cx-rx),x1=math.min(source.width-2,cx+rx);
        final y0=math.max(2,cy-ry),y1=math.min(source.height-2,cy+ry);
        double score(int fixed,int lo,int hi,bool vertical){
          if(hi-lo<8)return 0;
          var count=0;
          for(var i=lo;i<=hi;i++){
            if(edge(vertical?fixed:i,vertical?i:fixed,vertical)>18)count++;
          }
          return count/(hi-lo+1);
        }
        final left=<int>[],right=<int>[],top=<int>[],bottom=<int>[];
        for(var i=x0;i<=x1;i++){
          if(i<(x*sx).floor()-2&&score(i,y0,y1,true)>.23)left.add(i);
          if(i>((x+w)*sx).ceil()+2&&score(i,y0,y1,true)>.23)right.add(i);
        }
        for(var i=y0;i<=y1;i++){
          if(i<(y*sy).floor()-2&&score(i,x0,x1,false)>.23)top.add(i);
          if(i>((y+h)*sy).ceil()+2&&score(i,x0,x1,false)>.23)bottom.add(i);
        }
        if(left.isEmpty||right.isEmpty||top.isEmpty||bottom.isEmpty)continue;
        // Test the strongest candidate edges rather than the nearest edge
        // (nearby letters, wave artwork and dashed borders can confuse that).
        List<int> strongest(List<int> values,int lo,int hi,bool vertical){
          values.sort((a,b)=>score(b,lo,hi,vertical).compareTo(score(a,lo,hi,vertical)));
          final result=<int>[];
          for(final v in values){if(result.every((p)=>(p-v).abs()>2))result.add(v);if(result.length>=5)break;}
          return result;
        }
        var l=0,r=0,t=0,b=0;double best=0;
        final ls=strongest(left,y0,y1,true),rs=strongest(right,y0,y1,true),ts=strongest(top,x0,x1,false),bs=strongest(bottom,x0,x1,false);
        for(final ll in ls)for(final rr in rs)
          for(final tt in ts)for(final bb in bs){
            final ww=rr-ll,hh=bb-tt;
            if(ww<12||hh<12||ww/hh<.65||ww/hh>1.7)continue;
            final edges=[score(ll,tt,bb,true),score(rr,tt,bb,true),score(tt,ll,rr,false),score(bb,ll,rr,false)];
            if(edges.any((v)=>v<.34))continue;
            final quality=edges.reduce((a,b)=>a+b)/4;
            if(quality>best){best=quality;l=ll;r=rr;t=tt;b=bb;}
          }
        if(best<.42)continue;
        final ww=(r-l-4)/sx,hh=(b-t-4)/sy;
        if(ww<=0||hh<=0||ww/hh<.65||ww/hh>1.7)continue;
        final rw=(page['printWidthMm'] as num)*ww/pw,rh=(page['printHeightMm'] as num)*hh/ph;
        if(role=='qr'&&(rw<12||rh<12)||role=='photo'&&(rw<8||rh<10))continue;
        final nx=(l+2)/sx,ny=(t+2)/sy;
        if(slots.any((q)=>q['side']==side&&q['key']!='__static'&&
          nx<(q['x'] as num)+(q['width'] as num)&&(q['x'] as num)<nx+ww&&
          ny<(q['y'] as num)+(q['height'] as num)&&(q['y'] as num)<ny+hh))continue;
        slots.add({'key':role,'side':side,'x':nx,'y':ny,'width':ww,'height':hh,
          'sample_x':x,'sample_y':y,'sample_width':w,'sample_height':h,
          'roleConfidence':'medium','roleEvidence':'explicit_label_and_border','reviewRequired':true});
      }
    }
  }
  static Uint8List cleanFlatRegions(Uint8List bytes,IdCardManifest manifest,String side,{bool allowSmoothGradient=false,List<Map<String,dynamic>>? sampleMasks}){
    if(bytes.length>8*1024*1024)throw const FormatException('Source raster is too large.');
    final decoded=img.decodePng(bytes);
    if(decoded==null||decoded.width*decoded.height>20000000||
        (decoded.width/decoded.height-manifest.width/manifest.height).abs()>.01)
      throw const FormatException('Source raster dimensions differ from the template.');
    final source=decoded.convert(format:img.Format.uint8,numChannels:4);
    final output=img.Image.from(source);
    final sx=source.width/manifest.width,sy=source.height/manifest.height;
    final masks=sampleMasks??[for(final r in manifest.regions) {'side':r.side,'key':r.key,'x':r.x,'y':r.y,'width':r.width,'height':r.height}];
    for(final r in masks.where((r)=>r['side']==side)){
      final x=(r['x'] as num).toDouble(),y=(r['y'] as num).toDouble(),w=(r['width'] as num).toDouble(),h=(r['height'] as num).toDouble();
      if(![x,y,w,h].every((v)=>v.isFinite)||x<0||y<0||w<=0||h<=0||x+w>manifest.width||y+h>manifest.height)throw const FormatException('Invalid sample removal mask.');
      final key=r['key'];
      // Expand by one pixel to clear edge anti-aliasing, then inspect the
      // untouched exterior ring. Refuse to guess a non-flat background.
      final x0=(x*sx).floor()-1,y0=(y*sy).floor()-1;
      final x1=((x+w)*sx).ceil()+1,y1=((y+h)*sy).ceil()+1;
      if(x0<1||y0<1||x1>=source.width-1||y1>=source.height-1)
        throw FormatException('$key: sample touches the artwork edge; use clean source artwork.');
      final left=x0-1,right=x1+1,top=y0-1,bottom=y1+1;
      // Never sample a neighbouring field's sample pixels when repairing
      // this field. The union-mask repair can safely handle adjacent masks.
      for(final other in masks.where((v)=>v['side']==side&&!identical(v,r))){
        final ox=((other['x'] as num)*sx).floor()-2,oy=((other['y'] as num)*sy).floor()-2;
        final ex=(((other['x'] as num)+(other['width'] as num))*sx).ceil()+2;
        final ey=(((other['y'] as num)+(other['height'] as num))*sy).ceil()+2;
        if(left<=ex&&right>=ox&&top<=ey&&bottom>=oy)
          throw const FormatException('Adjacent sample regions require combined artwork repair.');
      }
      List<int> rgb(int x,int y){final p=source.getPixel(x,y);return [p.r.toInt(),p.g.toInt(),p.b.toInt()];}
      final tl=rgb(left,top),tr=rgb(right,top),bl=rgb(left,bottom),br=rgb(right,bottom);
      int channel(int x,int y,int c){
        if(!allowSmoothGradient)return tl[c];
        final u=(x-left)/(right-left),v=(y-top)/(bottom-top);
        return ((1-v)*((1-u)*tl[c]+u*tr[c])+v*((1-u)*bl[c]+u*br[c])).round().clamp(0,255).toInt();
      }
      bool matches(int x,int y){
        final pixel=source.getPixel(x,y),actual=rgb(x,y);
        return pixel.a==255&&List.generate(3,(c)=>(actual[c]-channel(x,y,c)).abs()).every((d)=>d<=3);
      }
      // Check the outer boundary ring to reject crossing rules, shapes or
      // patterns. Interior artwork remains unknowable; final visual approval
      // is mandatory, even for an apparently smooth gradient.
      for(var x=left;x<=right;x++){
        if(!matches(x,top)||!matches(x,bottom))throw FormatException('$key: complex background; provide clean original artwork.');
      }
      for(var y=top+1;y<bottom;y++){
        if(!matches(left,y)||!matches(right,y))throw FormatException('$key: complex background; provide clean original artwork.');
      }
      if(!allowSmoothGradient){
        img.fillRect(output,x1:x0,y1:y0,x2:x1,y2:y1,color:img.ColorRgba8(tl[0],tl[1],tl[2],255));
      }else{
        for(var y=y0;y<=y1;y++)for(var x=x0;x<=x1;x++)
          output.setPixelRgba(x,y,channel(x,y,0),channel(x,y,1),channel(x,y,2),255);
      }
    }
    return Uint8List.fromList(img.encodePng(output));
  }
  /// Approximate only hidden pixels from the exterior of the union of
  /// reviewed masks. Never reuse a pixel from any sample rectangle.
  /// This cannot recover artwork that is absent from the original PDF.
  static Uint8List reconstructArtwork(Uint8List bytes,IdCardManifest manifest,String side,List<Map<String,dynamic>> masks){
    if(bytes.length>8*1024*1024)throw const FormatException('Source raster is too large.');
    final decoded=img.decodePng(bytes);
    if(decoded==null||decoded.width*decoded.height>6000000||
       (decoded.width/decoded.height-manifest.width/manifest.height).abs()>.01)
      throw const FormatException('Automatic background repair needs a bounded source raster.');
    final source=decoded.convert(format:img.Format.uint8,numChannels:4),output=img.Image.from(source);
    final w=source.width,h=source.height,sx=w/manifest.width,sy=h/manifest.height;
    final masked=Uint8List(w*h);
    for(final r in masks.where((r)=>r['side']==side)){
      final x=(r['x'] as num).toDouble(),y=(r['y'] as num).toDouble(),rw=(r['width'] as num).toDouble(),rh=(r['height'] as num).toDouble();
      if(![x,y,rw,rh].every((v)=>v.isFinite)||x<0||y<0||rw<=0||rh<=0||x+rw>manifest.width||y+rh>manifest.height)
        throw const FormatException('Invalid sample removal mask.');
      final l=math.max(0,(x*sx).floor()-2),t=math.max(0,(y*sy).floor()-2);
      final right=math.min(w,((x+rw)*sx).ceil()+2),bottom=math.min(h,((y+rh)*sy).ceil()+2);
      if(l==0||t==0||right==w||bottom==h)throw const FormatException('Sample reaches edge; clean original artwork required.');
      for(var yy=t;yy<bottom;yy++)masked.fillRange(yy*w+l,yy*w+right,1);
    }
    if(masked.where((v)=>v!=0).length>w*h*.38)
      throw const FormatException('Too much hidden artwork for reliable automatic repair; use clean original.');
    // For each row, locate unmasked left/right exterior pixels. Use
    // horizontal interpolation for short text rows and blend with the
    // nearest vertical boundaries. All samples are outside every mask.
    final up=Int32List(w*h),down=Int32List(w*h);
    up.fillRange(0,up.length,-1);down.fillRange(0,down.length,-1);
    for(var x=0;x<w;x++){
      var last=-1;
      for(var y=0;y<h;y++){final i=y*w+x;if(masked[i]==0){last=y;}else{up[i]=last;}}
      last=-1;
      for(var y=h-1;y>=0;y--){final i=y*w+x;if(masked[i]==0){last=y;}else{down[i]=last;}}
    }
    for(var y=0;y<h;y++){
      var x=0;
      while(x<w){
        if(masked[y*w+x]==0){x++;continue;}
        final l=x-1;
        while(x<w&&masked[y*w+x]!=0){x++;}
        final r=x;
        if(l<0||r>=w)throw const FormatException('Missing artwork boundary.');
        final a=source.getPixel(l,y),b=source.getPixel(r,y);
        for(var xx=l+1;xx<r;xx++){
          final i=y*w+xx,t=up[i],bottom=down[i];
          if(t<0||bottom<0)throw const FormatException('Missing artwork boundary.');
          final c=source.getPixel(xx,t),d=source.getPixel(xx,bottom);
          final u=(xx-l)/(r-l),v=(y-t)/(bottom-t);
          final wx=1.0/(r-l),wy=1.0/(bottom-t);
          int blend(num p,num q,num m,num n)=>((wx*(p+(q-p)*u)+wy*(m+(n-m)*v))/(wx+wy)).round().clamp(0,255).toInt();
          output.setPixelRgba(xx,y,blend(a.r,b.r,c.r,d.r),blend(a.g,b.g,c.g,d.g),blend(a.b,b.b,c.b,d.b),255);
        }
      }
    }
    return Uint8List.fromList(img.encodePng(output));
  }
  /// A clean companion must have the same exact rendered pixel grid, and
  /// differ from the filled source only inside reviewed sample masks.
  /// This is a fidelity check, not proof all private data was removed.
  static Uint8List verifyCleanCompanion(Uint8List filled,Uint8List clean,IdCardManifest manifest,String side,List<Map<String,dynamic>> masks){
    if(filled.length>8*1024*1024||clean.length>8*1024*1024)throw const FormatException('Clean artwork exceeds 8 MiB.');
    final a=img.decodePng(filled),b=img.decodePng(clean);
    if(a==null||b==null||a.width!=b.width||a.height!=b.height||a.width*a.height>20000000)
      throw const FormatException('Clean artwork pixel dimensions must exactly match the filled source.');
    final sx=a.width/manifest.width,sy=a.height/manifest.height;
    if((a.width/a.height-manifest.width/manifest.height).abs()>.01)
      throw const FormatException('Companion aspect ratio differs.');
    // A one-byte per-pixel mask avoids O(pixels * regions). A 20MP limit
    // bounds additional memory. Only reviewed sample rectangles may differ.
    final allowed=Uint8List(a.width*a.height);
    for(final r in masks.where((r)=>r['side']==side)){
      final x=(r['x'] as num).toDouble(),y=(r['y'] as num).toDouble(),w=(r['width'] as num).toDouble(),h=(r['height'] as num).toDouble();
      if(![x,y,w,h].every((v)=>v.isFinite)||x<0||y<0||w<=0||h<=0||x+w>manifest.width||y+h>manifest.height)throw const FormatException('Invalid companion mask.');
      final l=((x*sx).floor()-2).clamp(0,a.width).toInt(),t=((y*sy).floor()-2).clamp(0,a.height).toInt();
      final right=(((x+w)*sx).ceil()+2).clamp(0,a.width).toInt(),bottom=(((y+h)*sy).ceil()+2).clamp(0,a.height).toInt();
      for(var yy=t;yy<bottom;yy++)allowed.fillRange(yy*a.width+l,yy*a.width+right,1);
    }
    final source=a.convert(format:img.Format.uint8,numChannels:4),target=b.convert(format:img.Format.uint8,numChannels:4);
    var changedInside=false;
    for(var y=0;y<source.height;y++)for(var x=0;x<source.width;x++){
      final p=source.getPixel(x,y),q=target.getPixel(x,y);
      final changed=(p.r-q.r).abs()>2||(p.g-q.g).abs()>2||(p.b-q.b).abs()>2||(p.a-q.a).abs()>2;
      if(!changed)continue;
      if(allowed[y*source.width+x]==0)throw const FormatException('Clean artwork changes pixels outside the sample removal regions. Review masks or use the matching clean original.');
      changedInside=true;
    }
    if(!changedInside&&masks.any((r)=>r['side']==side))throw const FormatException('Clean artwork still matches the filled sample. Verify sample removal.');
    return Uint8List.fromList(img.encodePng(target));
  }
  static Map<String,dynamic> package(String id,List<Map<String,dynamic>> pages,
      List<Map<String,dynamic>> slots,Map<String,Uint8List> rasters,{bool allowSmoothGradient=false,bool allowApproximateRepair=false,Map<String,Uint8List> cleanArtwork=const {},Map<String,Uint8List> cleanCompanion=const {}}){
    if(pages.isEmpty||pages.length>2||slots.length>128)throw const FormatException('Invalid review pages or slot count.');
    final first=pages.first;
    final w=(first['canvasWidth'] as num).toDouble(),h=(first['canvasHeight'] as num).toDouble();
    if(pages.any((p)=>((p['canvasWidth'] as num)-w).abs()>.01||((p['canvasHeight'] as num)-h).abs()>.01))
      throw const FormatException('Front/back page sizes differ.');
    if(slots.any((r)=>r['key']==''||r['roleConfidence']=='low'))throw const FormatException('Confirm uncertain images or explicitly mark them static artwork.');
    final issue=slots.map(readabilityIssue).whereType<String>().firstOrNull;
    if(issue!=null)throw FormatException(issue);
    final regions=<Map<String,dynamic>>[],masks=<Map<String,dynamic>>[];
    for(final slot in slots){
      final key=slot['key']?.toString()??'';
      if(key=='__static')continue;
      if(!textFields.contains(key)&&!imageFields.contains(key)&&key!='qr')throw const FormatException('Unknown field.');
      final type=kind(key);
      masks.add({'side':slot['side'],'key':key,for(final k in ['x','y','width','height'])k:slot['sample_$k']??slot[k]});
      final font=((slot['fontSize'] as num?)??math.max(6,math.min(72,((slot['height'] as num?)??12)*.8))).toDouble();
      regions.add({'key':key,'side':slot['side'],'kind':type,'x':slot['x'],'y':slot['y'],
        'width':slot['width'],'height':slot['height'],'fontSize':font,'minFontSize':6,
        'textColor':slot['textColor']??'#000000','align':slot['align']??'left','bold':type=='text'&&slot['bold']==true,'required':key=='name'||key=='qr',
        'rotation':type=='text'&&slot['rotation']==-90?-90:0,'fit':key=='photo'?'cover':'contain','shape':type=='image'&&slot['oval']==true?'oval':'rect',
        'wrap':type=='text'&&slot['wrap']==true,'maxLines':type=='text'&&slot['wrap']==true?2:1});
    }
    if(!regions.any((r)=>r['key']=='name'&&r['side']=='front')||!regions.any((r)=>r['key']=='qr'))
      throw const FormatException('Map the front name and authentication QR before review.');
    final json=<String,dynamic>{'id':id,'version':1,'canvasWidth':w,'canvasHeight':h,
      'printWidthMm':first['printWidthMm'],'printHeightMm':first['printHeightMm'],'regions':regions};
    final manifest=IdCardManifest.fromJson(json);
    if(manifest.hasBack!=(pages.length==2))throw const FormatException('Map at least one field on each source side.');
    final backgrounds=<String,String>{};
    for(final side in ['front',if(manifest.hasBack)'back']){
      final source=rasters[side];
      if(source==null)throw const FormatException('Source page missing.');
      final companion=cleanCompanion[side],clean=cleanArtwork[side];
      final cleanOriginal=companion??clean;
      if(cleanOriginal!=null){
        backgrounds[side]=base64Encode(verifyCleanCompanion(source,cleanOriginal,manifest,side,masks));
      }else{
        try{
          backgrounds[side]=base64Encode(cleanFlatRegions(source,manifest,side,allowSmoothGradient:allowSmoothGradient,sampleMasks:masks));
        }on FormatException{
          if(!allowApproximateRepair)rethrow;
          backgrounds[side]=base64Encode(reconstructArtwork(source,manifest,side,masks));
        }
      }
    }
    final result=<String,dynamic>{'manifest':json,'backgrounds':backgrounds};
    if(utf8.encode(jsonEncode(result)).length>8*1024*1024)throw const FormatException('Reviewed package exceeds 8 MiB.');
    return result;
  }
}
