import 'dart:math' as math;
import 'package:image/image.dart' as img;

/// Conservative, local-only automatic A4 page extraction for a bright
/// rectangular sheet against a clearly darker camera background.
///
/// If evidence is weak, return null so the existing A4 validator rejects
/// the upload. No manual corner editing and no invented page geometry.
class TemplateForgePhotoNormalizer {
  static num _luminance(img.Image image,int x,int y){
    final p=image.getPixel(x,y);
    return p.r+p.g+p.b;
  }

  static ({int left,int right})? _brightRun(img.Image image,int y){
    var bestLeft=-1,bestRight=-1,start=-1;
    for(var x=0;x<=image.width;x++){
      final bright=x<image.width &&
        _luminance(image,x,y)>590;
      if(bright && start<0)start=x;
      if(!bright && start>=0){
        if(x-start>bestRight-bestLeft){
          bestLeft=start;bestRight=x-1;
        }
        start=-1;
      }
    }
    return bestLeft>=0 && bestRight-bestLeft>=image.width*.35
      ?(left:bestLeft,right:bestRight):null;
  }

  static img.Image? rectifyVerifiedA4(img.Image source){
    if(source.width<240||source.height<240)return null;
    // Sampled analysis prevents large phone photos from exhausting memory.
    final small=img.copyResize(source,
      width:math.min(640,source.width),
      interpolation:img.Interpolation.average);
    final w=small.width,h=small.height;
    if(h<150)return null;
    final corners=[
      _luminance(small,0,0),_luminance(small,w-1,0),
      _luminance(small,0,h-1),_luminance(small,w-1,h-1),
    ];
    final center=_luminance(small,w~/2,h~/2);
    if(corners.any((v)=>v>330)||center<610)return null;
    int? top,bottom;
    for(var y=2;y<h-2;y++){
      if(_brightRun(small,y)!=null){top=y;break;}
    }
    for(var y=h-3;y>2;y--){
      if(_brightRun(small,y)!=null){bottom=y;break;}
    }
    if(top==null||bottom==null||bottom-top<h*.55 ||
      bottom-top>h*.97||top<5||bottom>h-6)return null;
    final a=_brightRun(small,math.min(bottom,top+4));
    final b=_brightRun(small,math.max(top,bottom-4));
    if(a==null||b==null)return null;
    final topWidth=a.right-a.left,bottomWidth=b.right-b.left;
    if(topWidth<w*.45||bottomWidth<w*.45 ||
      (topWidth-bottomWidth).abs()>w*.22)return null;
    final avgWidth=(topWidth+bottomWidth)/2;
    final aspect=avgWidth/(bottom-top);
    if((aspect-210/297).abs()>.12)return null;
    // The four corners must be inside the image and distinctly inside
    // the dark surrounding surface, not the image border itself.
    if(math.min(a.left,b.left)<5 ||
      math.max(a.right,b.right)>w-6)return null;
    final sx=source.width/w,sy=source.height/h;
    final targetWidth=math.min(1900,source.width);
    final targetHeight=(targetWidth*297/210).round();
    if(targetWidth<200||targetHeight<200)return null;
    final output=img.copyRectify(source,
      topLeft:img.Point((a.left*sx).round(),(top*sy).round()),
      topRight:img.Point((a.right*sx).round(),(top*sy).round()),
      bottomLeft:img.Point((b.left*sx).round(),(bottom*sy).round()),
      bottomRight:img.Point((b.right*sx).round(),(bottom*sy).round()),
      interpolation:img.Interpolation.linear,
      toImage:img.Image(width:targetWidth,height:targetHeight));
    return output;
  }
}
