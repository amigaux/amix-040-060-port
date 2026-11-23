#!/bin/bash
# cut 68060-261123-69 (as -68 with kabi k46.1.7, the sd_limits check, the stock rlimits and their text, the 4 KiB raw pieces; as -67; as -66 with kabi k46.1.6 and the fb_register check; as -61, as -60, as -59) (as -58, and the sidecar carries kbootset-min=, C2-3 version 10): -61's post-c.sh with its directories under the cut's run root W (cut.sh lays it out:
# W/amix-kerntools, W/amix-040-060-port, W/port, W/amix at 812c763e).  CONTROL (optional) is the frozen candidate-3
# kernel emit and k0-gates compare against; without it emit runs --no-oracle alone and k0-gates reports the
# control rows.  -61's M-REG1 measurement is left out (it reads, it does not shape the bytes).
# The proof after build-m.sh (the -61 recipe): sddevsize, the support probe, then steps 9-10 (relink-040-dlm.sh --fill:
# mkksym -f, mkident --fill/--check, mkabi.py --check against the rewritten
# reference, ksymgate), emit c0-u6 twice, k0-gates (families-m.json), then on the emitted image: mkident --check,
# the gate again, mkabi again, the sidecar (C2-3 v5 with abi=), M-REG1, nm.  Kerntools tools are only read.
set -euo pipefail
W=${W:?}
KT=$W/amix-kerntools; R=$W/amix-040-060-port; T=$W/port; S=$T/build/dlm-rev
TAG=${1:-m}; L=$W/log/$TAG; K=$W/kernels/$TAG
rm -rf ${K:?}/sd ${K:?}/w ${K:?}/w.dlm ${K:?}/w.gate ${K:?}/w.abi ${K:?}/w.abi.txt ${W:?}/chains1/${TAG:?} ${W:?}/chains2/${TAG:?} ${W:?}/out/${TAG:?}
cd $KT
python3 tools/kernel-sddevsize-inject.py inject $K/unix-fpe -o $K/sd > $L/9-sddevsize.log 2>&1; tail -n 1 $L/9-sddevsize.log | cut -c1-90
python3 tools/kernel-support-probe-inject.py inject $K/sd -o $K/w > $L/10-wd7.log 2>&1; tail -n 1 $L/10-wd7.log | cut -c1-90
grep '^  .text  ' $L/10-wd7.log || true
# steps 9-10 on the last form whose layout changes (the support probe grows .text); emit only patches .data words
(cd $T && DLM_REPO=$W/amix/kernel/dlm DLM_REV=812c763e DLM_KABI=k46.1.7 sh relink-040-dlm.sh --fill $K/w) > $L/10f-fill.log 2>&1 \
	|| { cat $L/10f-fill.log; exit 1; }
grep 'ident=\|arena=\|ksym=\|abi=\|mkabi\|ksymgate:\|sizes filled' $L/10f-fill.log
ABI=$(sed -n 's/^abi=//p' $K/w.abi); [ -n "$ABI" ]
[ "$(wc -l < $K/w.abi)" = 1 ] && echo "mkabi --check: no moved line, $(cat $K/w.abi)"
for n in 1 2; do
python3 tools/emit-family-chains.py --families $W/families-c.json --family KD060-Z --base $K/w \
	--out $W/chains$n/$TAG --cputype 60 --bo-size 61440 --cards 0 --units 6 --no-oracle \
	${CONTROL:+--control "$CONTROL" --control-sha256 5aa7d732c3a919c74c4f46cbb679528edfb7848e1761454b0487c2672f405f6e --control-sum-r 49323} \
	> $L/11-emit$n.log 2>&1
done
U=$W/chains1/$TAG/KD060-Z-c0-u6
cmp $U $W/chains2/$TAG/KD060-Z-c0-u6 && echo "emit: two runs byte-identical"
tail -n 1 $L/11-emit1.log
python3 tools/k0-gates.py --families $W/families-c.json check --manifest $W/chains1/$TAG/MANIFEST.json \
	--objects-dir $T/build > $L/12-gates.log 2>&1 || true
tail -n 1 $L/12-gates.log
cd $T
python3 $S/kit/tools/mkident.py --check $U
python3 $S/kit/tools/ksymgate.py $S/axrel $U $S/kit/abi/k46/ddi.list $S/kit/abi/k46/core.list > $L/13-gate-shipped.log 2>&1 \
	&& echo "ksymgate on the shipped form: $(grep -c '^PASS' $L/13-gate-shipped.log) of 12" || { cat $L/13-gate-shipped.log; exit 1; }
mkdir -p $W/out/$TAG; cp $U $W/out/$TAG/unix
python3 $S/kit/tools/mkabi.py --text $W/out/$TAG/abi-k46.1.7.txt $U $S/kit/abi/k46/ddi.list $S/core/dlm_offs.h > $L/13b-mkabi-shipped.log
grep -qx "abi=$ABI" $L/13b-mkabi-shipped.log && cmp $W/out/$TAG/abi-k46.1.7.txt $S/kit/abi/k46/abi-k46.1.7.txt \
	&& echo "mkabi on the shipped form: abi=$ABI, its text = abi/k46/abi-k46.1.7.txt at the pin"
# k46.1.6 is claimed only with its name: fb_register defined and in the minor-6 list (awk, not grep -q: pipefail)
m68k-linux-gnu-nm $U | awk '$2=="T" && $3=="fb_register"{f=1} END{exit !f}' && grep -qx "fb_register func 6" $S/kit/abi/k46/ddi.list \
	&& echo "fb_register: defined (T) and in ddi.list as func, minor 6" || { echo "fb_register is not defined, or not in ddi.list"; exit 1; }
# k46.1.7 is claimed only with its name: sd_limits (core 0059, C4-7) defined and in the minor-7 list
m68k-linux-gnu-nm $U | awk '$2=="T" && $3=="sd_limits"{f=1} END{exit !f}' && grep -qx "sd_limits func 7" $S/kit/abi/k46/ddi.list \
	&& echo "sd_limits: defined (T) and in ddi.list as func, minor 7" || { echo "sd_limits is not defined, or not in ddi.list"; exit 1; }
# the shipped image: the stock soft data and vmem limits (16 MiB, hard unlimited), read back from rlimits[], and the
# package text saying the same (kernel/k30's rlimits-check.py at the pin, against kern46m-new-in.txt); the 4 KiB raw pieces
python3 src/patch_rlimits.py --expect stock $U
python3 $KT/tools/rlimits-check.py $U $W/kern46m-new-in.txt
python3 src/patch_pageio4k.py --check $U
strings -a $U | grep -F "boot-class modules load from the first sysinit entry" | sed 's/^/image carries: /'
echo "stub objects in the splice: $(ls $S/obj | grep -ci stub || true)"; grep -h 'every listed name' $K/w.gate
# the sidecar's pin= is the core's toolchain pin (kernel/dlm/toolchain.pin at the cut's amix), checked after
PIN=gcc-$(awk '$1=="gcc"{print $2}' $S/kit/toolchain.pin)-$(awk '$1=="commit"{print $2}' $S/kit/toolchain.pin)
python3 tools/kabi-sidecar.py $W/out/$TAG/unix --family generic --pin $PIN --abi $ABI --kbootset-min $W/amix/kernel/dlm/core/kbootset-min -o $W/out/$TAG/kabi > $L/14-sidecar.log 2>&1 || { cat $L/14-sidecar.log; exit 1; }
python3 tools/kabi-sidecar.py $W/out/$TAG/unix --family generic --pin $PIN --abi $ABI --kbootset-min $W/amix/kernel/dlm/core/kbootset-min -o $W/out/$TAG/kabi-2 > /dev/null
cmp $W/out/$TAG/kabi $W/out/$TAG/kabi-2 && rm ${W:?}/out/${TAG:?}/kabi-2 && echo "sidecar: two runs identical"
python3 tools/kabi-sidecar.py --check $W/out/$TAG/unix $W/out/$TAG/kabi
[ "$(sed -n 's/^pin=//p' $W/out/$TAG/kabi)" = "$PIN" ] && echo "kabi pin=$PIN = kernel/dlm/toolchain.pin" \
	|| { echo "kabi pin= is not $PIN (kernel/dlm/toolchain.pin)"; exit 1; }
strings -a $U | grep -F "$PIN" > /dev/null && echo "image carries DLM_PIN $PIN" || { echo "the image does not carry $PIN"; exit 1; }
diff <(grep '^ident=\|^arena=\|^ksym=' $W/out/$TAG/kabi) <(grep '^ident=\|^arena=\|^ksym=' $K/w.dlm) && echo "sidecar's ident/arena/ksym = mkident --fill's lines"
cat $W/out/$TAG/kabi
python3 src/patch_sd4card.py --check $U 2>&1 | tail -1
for t in patch_dlm_halt patch_free_brow patch_krnx_quiet; do python3 src/$t.py --check $U 2>&1 | tail -1; done; python3 src/patch_dlm_call.py --check $U sd4_init sd4_noclose dlm_sd_close | tail -1; python3 src/patch_dlm_call.py --check $U rth1_mountroot rth1_nomarc dlm_marc_root | tail -1
python3 src/check_root_family.py $U 2>&1 | tail -3
echo "nm weak: $(m68k-linux-gnu-nm $U | awk '$2 ~ /^[WwVv]$/' | wc -l); undefined: $(m68k-linux-gnu-nm -u $U | awk '{print $2}' | tr '\n' ' ')"
sha256sum $U $W/out/$TAG/unix; sum -r $U
