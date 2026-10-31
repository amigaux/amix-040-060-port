#!/bin/bash
# cut 68060-261031-52 (as -51): -61's post-c.sh with its directories under the cut's run root W (cut.sh lays it out:
# W/amix-kerntools, W/amix-040-060-port, W/port, W/dlm-e45b061).  CONTROL (optional) is the frozen candidate-3
# kernel emit and k0-gates compare against; without it emit runs --no-oracle alone and k0-gates reports the
# control rows.  -61's M-REG1 measurement is left out (it reads, it does not shape the bytes).
# Q4-3 proof after build-m.sh (the -61 recipe): sddevsize, the W-D7 probe, then steps 9-10 (relink-040-dlm.sh --fill:
# mkksym -f, mkident --fill/--check, mkabi.py --check against the rewritten
# reference, ksymgate), emit c0-u6 twice, k0-gates (families-m.json), then on the emitted image: mkident --check,
# the gate again, mkabi again, the sidecar (C2-3 v5 with abi=), M-REG1, nm.  Kerntools tools are only read.
set -euo pipefail
W=${W:?}
KT=$W/amix-kerntools; R=$W/amix-040-060-port; T=$W/port; S=$T/build/dlm-rev
TAG=${1:-m}; L=$W/log/$TAG; K=$W/kernels/$TAG
rm -rf $K/sd $K/w $K/w.dlm $K/w.gate $K/w.abi $K/w.abi.txt $W/chains1/$TAG $W/chains2/$TAG $W/out/$TAG
cd $KT
python3 tools/kernel-sddevsize-inject.py inject $K/unix-fpe -o $K/sd > $L/9-sddevsize.log 2>&1; tail -n 1 $L/9-sddevsize.log | cut -c1-90
python3 tools/kernel-support-probe-inject.py inject $K/sd -o $K/w > $L/10-wd7.log 2>&1; tail -n 1 $L/10-wd7.log | cut -c1-90
grep '^  .text  ' $L/10-wd7.log || true
# steps 9-10 on the last form whose layout changes (W-D7 grows .text); emit only patches .data words
(cd $T && DLM_REPO=$W/dlm-e45b061 DLM_REV=e45b061 sh relink-040-dlm.sh --fill $K/w) > $L/10f-fill.log 2>&1 \
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
python3 $S/kit/tools/mkabi.py --text $W/out/$TAG/abi-k46.1.3.txt $U $S/kit/abi/k46/ddi.list $S/core/dlm_offs.h > $L/13b-mkabi-shipped.log
grep -qx "abi=$ABI" $L/13b-mkabi-shipped.log && cmp $W/out/$TAG/abi-k46.1.3.txt $S/kit/abi/k46/abi-k46.1.3.txt \
	&& echo "mkabi on the shipped form: abi=$ABI, its text = abi/k46/abi-k46.1.3.txt at the pin"
strings -a $U | grep -F "boot-class modules load from the first sysinit entry" | sed 's/^/image carries: /'
echo "stub objects in the splice: $(ls $S/obj | grep -ci stub || true)"; grep -h 'every listed name' $K/w.gate
python3 tools/kabi-sidecar.py $W/out/$TAG/unix --family generic --pin gcc-2.7.2.3-8949028 --abi $ABI -o $W/out/$TAG/kabi > $L/14-sidecar.log 2>&1 || { cat $L/14-sidecar.log; exit 1; }
python3 tools/kabi-sidecar.py $W/out/$TAG/unix --family generic --pin gcc-2.7.2.3-8949028 --abi $ABI -o $W/out/$TAG/kabi-2 > /dev/null
cmp $W/out/$TAG/kabi $W/out/$TAG/kabi-2 && rm $W/out/$TAG/kabi-2 && echo "sidecar: two runs identical"
python3 tools/kabi-sidecar.py --check $W/out/$TAG/unix $W/out/$TAG/kabi
diff <(grep '^ident=\|^arena=\|^ksym=' $W/out/$TAG/kabi) <(grep '^ident=\|^arena=\|^ksym=' $K/w.dlm) && echo "sidecar's ident/arena/ksym = mkident --fill's lines"
cat $W/out/$TAG/kabi
python3 src/patch_sd4card.py --check $U 2>&1 | tail -1
for t in patch_dlm_halt patch_free_brow patch_krnx_quiet; do python3 src/$t.py --check $U 2>&1 | tail -1; done; python3 src/patch_dlm_call.py --check $U sd4_init sd4_noclose dlm_sd_close | tail -1; python3 src/patch_dlm_call.py --check $U rth1_mountroot rth1_nomarc dlm_marc_root | tail -1
python3 src/check_root_family.py $U 2>&1 | tail -3
echo "nm weak: $(m68k-linux-gnu-nm $U | awk '$2 ~ /^[WwVv]$/' | wc -l); undefined: $(m68k-linux-gnu-nm -u $U | awk '{print $2}' | tr '\n' ' ')"
sha256sum $U $W/out/$TAG/unix; sum -r $U
