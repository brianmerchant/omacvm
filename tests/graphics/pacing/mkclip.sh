#!/bin/bash
# mkclip.sh: PQ (BT.2100) test bars at 100/203/400/600/1000 nits, 8-bit HEVC (the guest's x265 is 8-bit only):
# limited-range codes 127/143/159/168/181 = PQ 0.508/0.581/0.653/0.696/0.752.
cd /opt/pacing && ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=1920x1080:r=30:d=20,format=yuv420p" \
  -vf "geq=lum='if(lt(X,W/5),127,if(lt(X,2*W/5),143,if(lt(X,3*W/5),159,if(lt(X,4*W/5),168,181))))':cb=128:cr=128,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
  -c:v libx265 -pix_fmt yuv420p -preset ultrafast \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400" \
  hdr10-bars.mkv && chmod a+r hdr10-bars.mkv
