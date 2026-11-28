'use strict';
// Generated one-bit fictional reference artwork, no identities or school data.
// Each fixture is an image-only PDF; no text layer exists.
const {analyzePdf}=require('../functions/global-id-card-analysis');
const {deflateSync}=require('node:zlib');
const fixtures={
 hin:'eNrt2sFq2zAcx3GZDHQZ83WHgV6hD1CmFwuVoQMf9Qh5lDn44NdQ8aFXmV40EP7vLyfNPHBGLMwo4fehlyrhS2r/7QYsIgAAAAAAWMOJiYxihqpp7R57RANZioZsIOr4pyf+fSCV1j5CT27bi7vGWHfqNXLWc3m9sKu0rR6nnpBVcemltZye+aKs+JZ641+9tJbTI6Xs4fPU0zTrpbW8nrU/f5x7UXe9F2XqpbXcHjXvPdP17tRLa1nHz3LPTb0HHWY9lzcvxfOpV/P5LQPPi9eWfHZvLI6lpcpQ63heAtVTL+xVWstRDMrSJ0ONGFUbjexD6gmV1nI+n+ITEnnWnBh1H7/LPhq+/oSKefM36lFbz9dC+Bp1zyM9zR/tlH/M7EU9Xb8UoulJnOaZsq/fkWfEHi+950vvmNlTjuzrude+31+495p5/xPF6f5HfH3IWS/3flrJPz27Qc/pS08dNujNlBv/b6837rUb91427r3h6xwAAAAAAAAAAAAAwF067xcwCy818y0EoryPXnoCNepu+aWSumio47eEQKt6y2+3516/uufNf+lFGU0jt+t57omc3pXj52R84t7687H4yqiOFJ80vdS394KQV3te1VPPydt7nnt+eSvOW3rSP/XKdT233Ou9Sr0H7fSKv1d11z7fMKaeEaUzL35Vb/n4DVTatzQvnobh1l7kXljuBaqti0+qDcYXt/b43P6jV3NP99GE3ar5M4u9aLrW7fea52ks1/SmjU0LPd05EfemTw/CN+iNuvanXr26t/j2sh4L7rXpQfjK3uL9pSpp4PMh04PwLXqNosC9tF1nkx4vck8d6Nea3nnWroy72XaXQ8QuBwAAAAAAAAAAAAAAAAAAAAAAAAAAAACAj+03yaX5Rg==',
 ben:'eNrt2r9uGzccwHEqB/Q8FGGzeTDCvkK2DoE49jX6Ct08GOEpAqoMQX7oC7SPkhNU4La+Qqne0LG8qTTA8tcfz//VEwxSNwW/bwZbUvwJj+LRMUxEjuM4juO+iFp98ISvT/LE4ZdbcQoXRXU4YGFO8IKyB8+sgzrB88YfDEfSn/IcHgwnKlyf4A14MJyocX+CR1+7eTqhmsZcXo/4++MJDMHg9cPDXwuuNz5e0eHJo3zPH3qoTvJasfxK3IW4CvcPhEKnG/oo87yzFw9eFFePvVaWeA8CenHx2BNVthdM63XXd/Qp0Oo2XxugCQX0esAo9/Rc3nYTzDbcenVajb+RF5InB/ro6ZMq09tH3Q/keXo7dtiQZzUt8Wqge9tJdIt8z7ou7Xsa26Ugr9F0B2/Jq1uJdsj3mkuymg8K7cU3BuIL/TNNJV1v9V7izuXOX9TirZCxArq4s0sD/rVuquTFhZTY+UzvQ9Svlai8Apq1Jhiw7/RHgS1dp1OQ7V1dvNRKdltrYJfuDwMrWi8ivR90f8AfkOstyYNu2CL0abM3UJPnr2TyDHSbXM/8ojV5+9HbkLchL1zq5CF0be78pf2FPKvJi5K8ZvQMedtSr+oGmnuaP0Veu6TrDel6e/JcgRdFt4j1J7rhPodxvZC3IO8f8rDE++77CtfJo8cQX2pw43rBQi+8q2vcf1I3Hv6kYUD3ZvR2RZ6hoTnAW+/P9NaEV6NnxXmBp8nz8tbztIzXCOO+Ak6cFcxf+h4c7jzndVOjXI1eEKJgvSDtV/Heu9KtwnqLN3u2LfTw3gvaGpT7W8+d6vnxGzIMRR7HcRzHcRzHcRzHcRzHcRzHcVxB18/9hb++IK8V4nw8G/D/mruDAz+YLO/sOe/bPE885+UdKOpsOrswGWzTL6RU3nmdzjk5PD2lcu+l0wiodnmex3qYPtMEXievz/W6Y14s83ZHPZXt1eT1k/MXJaCCoLK8sBi9qZd8lTxXZ3lekLee9NyCBge2yvKcrz2KSW/vpK9hZ7O8IdY+ih+nXuqDdBV0Ps/D2oe3rya9KPcWupDpbXww0x7K3kMX8+aP1l8wq8n5Q6BL3uWtP2+St53+pyBdcqankzd5Qs8ZoEu2eV5M49OTXkDYo7zOvN/Ii3Jy/UUEGuK/+ftBPLr/OVO0v8Cx/SWUeX8f87DMw6Me5ns3c6+PvADz/t/Gynm9ZmZP1PN6ajWzJ2b2zvW887dU876/el7P4mf+AYPjOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOI7jOO65/gNiVa6K',
 asm:'eNrtmsGK40YQhtvRgvYQaHKbwzIdyGuEUSCBfY1AniC3HALy4IOPeoQ8ytro0Md9hLRQYI/TyqkXertS3fJ4J4mMKdun5f8Gz5Stmc/dXaWSBjcRAAAAAL4g/szflJmfxOpqX8ePoFbzE6/aK3VJF83B41RzpS9mwUR+9uyL/hp8HthIaV7ALX9dx46Kj+Zxadpf6dvMy3YYlyF/ZTrqOa2NLc8MhesSHPO6vY/KFN9DQ/HzsQ+XjC/n9T1PtPga8/LYJT5qZ98fY/F1V/h26pkSteTa4ytKU9SOf9aX+H6YfWvz0ueri32FNqn6pW+nhD4iS47sRMR/ZEZOdZ+zUqLAhRl+OVSnoJZ3TfZtufBGrryJfTmKNft0+o7iSlR7qo3G+jxOzxZPzuRoIHoM7OVeGJSoFXAXZV/Lvl326bXJkePzj30rX5H/TVQwP2nS9u+Gfas83/qVydFfLQX2KLehQXT2reyWOsst2UadV+2re5Mjbg7Zt/6xpzEKfFHbnn0Tz9Ib9pFr5kg1jn2xHmU+39ghaTtxFnZ18bVztGs4H/x245OV+HLtxYrrRdvNvvg4OzlK97leohnHXjQ+9oUV+zrb53qhgX0lepPrOTbj6H6X+IydvH+bfbuYfRv2lehNE/KFRegL2g5TZJ+x7j777CFKD3m+gcYxSHxU2WpKdfaVeqGnQ5QeFPs+sY8k60d79lE9Ja7ikt/SpTmKpV5I7PNWT7SdEl+L+qOPo9iGu+IbZL7wlnO8nWJraTj6OOKT93XxefW1xBdrCtyvPPvC0ccRF+a6+IJ6JfGl4vOKExuPvmjcirbzXUNSstutmi+XNlT/8fmaNu5wF+JFPr7HeMcVQnNXnn3JBENbf/AFqY/s/Dj6KF/SbbjIBwAAAAAAAAAAAAAAAAAAIObjuV/48AX5dkrdKfW8c+hfrJ+3Dfzcinyvz/m+lfnUOZ/s8zLrQjMtH+r2eeOTke1nsN7rqexY+b9v3WZfL/MFqqdoFn0h712ZP0WT+OwpX7rM15/0GbGvZt+4uH5Jd2S6aES+uCq+pUOhyj5fi3xBsW+z6PMrHlznKpHPhzqQWvQNXoe6653IN6U6JPXr0qExal91Nsh8VIf4/TeLvqQH19ko9G1DbJd9pMfQ2SRbP66/2D4urh91POVeVn+hzb798lt1ecpCX5N9w6Kv7XjKTuZLeXzNoi9SN5D+KDzf2Jf0Yv0l6niIn+T9IJ3sf769qL90p/pLvMz3dMpHl/nopI/kvnntmxMHutve2zh9W9/6xj7Z1sTzmMcb+9SNfXfNbdfvwdw2v81tfY7e4R8MAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAOMc/MJeZWQ=='
};
function imagePdf(encoded){
 const raster=Buffer.from(encoded,'base64');
 const content=Buffer.from('q 240 0 0 120 0 0 cm /Sample Do Q\n');
 const image=Buffer.concat([Buffer.from('<< /Type /XObject /Subtype /Image /Width 640 /Height 320 /ColorSpace /DeviceGray /BitsPerComponent 1 /Filter /FlateDecode /Length '+raster.length+' >>\nstream\n'),raster,Buffer.from('\nendstream')]);
 const objs=[Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),Buffer.from('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 120] /Resources << /XObject << /Sample 4 0 R >> >> /Contents 5 0 R >>'),image,Buffer.concat([Buffer.from('<< /Length '+content.length+' >>\nstream\n'),content,Buffer.from('endstream')])];
 const out=[Buffer.from('%PDF-1.4\n')],offsets=[0];let length=out[0].length;
 for(let i=0;i<objs.length;i++){const chunk=Buffer.concat([Buffer.from((i+1)+' 0 obj\n'),objs[i],Buffer.from('\nendobj\n')]);offsets.push(length);length+=chunk.length;out.push(chunk);}
 out.push(Buffer.from('xref\n0 '+offsets.length+'\n0000000000 65535 f \n'+offsets.slice(1).map(o=>String(o).padStart(10,'0')+' 00000 n \n').join('')+'trailer\n<< /Size '+offsets.length+' /Root 1 0 R >>\nstartxref\n'+length+'\n%%EOF\n'));
 return Buffer.concat(out);
}
(async()=>{
 const checks={};
 for(const [lang,kind] of [['hin','studentId'],['ben','teacherId'],['asm','otherStaffId']]){
  try{
   const bytes=imagePdf(fixtures[lang]);
   const before=await analyzePdf(bytes,'/usr/bin/pdftotext','/usr/bin/pdftohtml');
   const after=await analyzePdf(bytes,'/usr/bin/pdftotext','/usr/bin/pdftohtml',{ocr:true,rasterizer:'/usr/bin/pdftoppm'});
   checks[lang]={imageOnly:before.pages[0].candidates.length===0,recognized:after.pages[0].ocr?.state==='recognized',name:after.pages[0].candidates.some(r=>r.key==='name'),category:after.category.kind===kind};
  }catch(_){checks[lang]={error:true};}
 }
 const passed=Object.values(checks).every(c=>!c.error&&Object.values(c).every(Boolean));
 console.log('ID_SCANNED_PDF_CHECK '+JSON.stringify({passed,checks}));
 if(!passed)process.exitCode=1;
})().catch(()=>{console.log('ID_SCANNED_PDF_FAILED');process.exitCode=1;});
