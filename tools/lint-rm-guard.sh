#!/bin/sh
# lint-rm-guard.sh FILE... -- refuse an rm or mv whose path names a variable without the ${var:?} guard, so an
# empty variable can never turn `rm -rf "$DIR/x"` into `rm -rf /x`.  Prints each offending line; exit 1 if any.
# Comment lines are skipped.  Every variable in the command must be ${name:?}: $x and ${x} are refused alike.
bad=0
for f in "$@"; do
	[ -f "$f" ] || continue
	out=$(grep -n -E '(^|[;&|({ 	])(rm|mv)[ 	]' "$f" | grep -v '^[0-9]*:[ 	]*#' | awk '
		{ line = $0; sub(/^[0-9]+:/, "", line)
		  s = line; i = match(s, /(^|[;&|({ \t])(rm|mv)[ \t]/)
		  s = substr(s, i); e = match(s, /;|&&|\|\||\||\)|`/); if (e) s = substr(s, 1, e - 1)
		  t = s; gsub(/\$\{[A-Za-z0-9_]+:\?\}/, "", t)
		  if (t ~ /\$/) print }')
	[ -z "$out" ] || { echo "$out" | sed "s|^|$f:|"; bad=1; }
done
[ "$bad" = 0 ] && echo "lint-rm-guard: every rm/mv variable guarded" || { echo "lint-rm-guard: unguarded rm/mv above"; exit 1; }
