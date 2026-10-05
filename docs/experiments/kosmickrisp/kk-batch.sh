#!/bin/bash
# kk-batch.sh (root, in the VM): the measurement round for Venus on KosmicKrisp, one load at a time.
# Results: /root/kk/results/<test>-<n>.txt, summary lines in /root/kk/results/summary.txt
R=/root/kk/results; mkdir -p $R; T=/root/kk/kk-guest.sh
say() { echo "$(date +%H:%M:%S) $*" | tee -a $R/summary.txt; }
score() { grep -o -E "(vkmark|glmark2) Score: [0-9]+" "$1" | grep -o "[0-9]*$"; }
say "start; load $(cat /proc/loadavg)"
for i in 1 2 3; do $T vkmark --winsys headless > $R/vkmark-$i.txt 2>&1; say "vkmark headless 800x600 run $i: $(score $R/vkmark-$i.txt)"; done
$T vkmark --winsys headless -s 1920x1080 > $R/vkmark-1080.txt 2>&1; say "vkmark headless 1920x1080: $(score $R/vkmark-1080.txt)"
for i in 1 2 3; do
  $T glmark2-zink --off-screen > $R/glmark2-zink-$i.txt 2>&1; say "glmark2-es2 off-screen zink run $i: $(score $R/glmark2-zink-$i.txt)"
  $T glmark2-virgl --off-screen > $R/glmark2-virgl-$i.txt 2>&1; say "glmark2-es2 off-screen virgl run $i: $(score $R/glmark2-virgl-$i.txt)"
done
$T clpeak > $R/clpeak.txt 2>&1; say "clpeak done: $(grep -A1 -i 'float  :' $R/clpeak.txt | head -2 | tr -s ' ' | tr '\n' ' ')"
for i in 1 2 3; do
  $T gb-opencl > $R/gb-opencl-$i.txt 2>&1
  say "geekbench7 opencl run $i: $(grep -o 'https://browser.geekbench.com/v7/[a-z]*/[0-9]*' $R/gb-opencl-$i.txt | tail -1) $(grep -i -E 'OpenCL Score|score' $R/gb-opencl-$i.txt | tail -1)"
done
say "end; load $(cat /proc/loadavg)"
echo BATCH-DONE >> $R/summary.txt
