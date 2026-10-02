# fold-rodata.sh -- sourced by relink passes: fold_rodata OBJ moves every .rodata section of OBJ
# into .data, in place (2026-09-28, moved here from relink-040-fpe.sh on 2026-10-02 so the cdfs pass
# uses the same fold).
#
# Why: the kernel image has .text and .data and nothing between them, so a .rodata in a linked
# object makes the link's text/data non-contiguous.  T-9's -Dconst=__const__ is how one appears in
# objects compiled here (fpu_cordic.c's two const tables); a delivered object can carry one too.
#
# Section index, not name: objcopy keeps the index, so the same section is dumped before and after
# the rename and the bytes are compared, not assumed (hex rows only: the header names it).  Its
# symbols must turn from r/R into d/D, and none may be left anywhere else.
fold_rodata() {
	R=$(m68k-linux-gnu-readelf -SW "$1" | awk '{gsub(/[][]/,"")} $2 ~ /^\.rodata/ {print $1":"$2}')
	RSYM=$(m68k-linux-gnu-nm "$1" | awk '$2=="r"||$2=="R"{print $3}')
	for e in $R; do
		i=${e%%:*}; s=${e#*:}
		B=$(m68k-linux-gnu-readelf -x "$i" "$1" | grep "^  0x")
		m68k-linux-gnu-objcopy --rename-section "$s=.data,alloc,load,data,contents" "$1" "$1" \
			|| { echo "[FAIL] cannot fold $s of $1 into .data"; exit 1; }
		m68k-linux-gnu-readelf -SW "$1" | awk -v i="$i" '{gsub(/[][]/,"")} $1==i && $2==".data"{f=1} END{exit !f}' \
			|| { echo "[FAIL] $1: section $i is not .data after the fold"; exit 1; }
		[ "$B" = "$(m68k-linux-gnu-readelf -x "$i" "$1" | grep "^  0x")" ] \
			|| { echo "[FAIL] $1: section $i bytes changed in the fold"; exit 1; }
		echo "      $(basename "$1"): $s (section $i) folded into .data, bytes identical"
	done
	for y in $RSYM; do
		m68k-linux-gnu-nm "$1" | awk -v y="$y" '$3==y && ($2=="d"||$2=="D"){f=1} END{exit !f}' \
			|| { echo "[FAIL] $1: $y did not move into .data"; exit 1; }
	done
	[ -z "$RSYM" ] || echo "      $(basename "$1"): now in .data: $(echo $RSYM)"
	! m68k-linux-gnu-readelf -SW "$1" | grep -q '\.rodata' \
		|| { echo "[FAIL] $1 still carries .rodata"; exit 1; }
}
