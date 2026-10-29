# dlm-rev.sh -- sourced; resolves the module core's revision and where its tree sits in it.
#
#   . "$HERE/tools/dlm-rev.sh"
#   dlm_rev                         # in: DLM_REPO, DLM_REV; out: DLM_GIT, REV, DLM_PFX
#   dlm_archive core abi ... | tar -x --strip-components=$DLM_STRIP -C <dir>
#   git -C "$DLM_GIT" show "$REV:${DLM_PFX}abi/k46/core.list"
#
# The core lives in the amix monorepo at kernel/dlm (DLM_REPO defaults to ../amix/kernel/dlm beside
# this repository).  It moved there by a subtree merge, so a revision from before the move is the
# same commit as in the standalone amix-dlm, with the core at the top of its tree; a later one has
# it under kernel/dlm.  DLM_PFX is whichever of the two the revision has ("kernel/dlm/" or ""), so
# a pinned pre-move revision yields the same files as it did from amix-dlm.  DLM_REPO may also be
# a standalone amix-dlm checkout.

dlm_rev() {
	DLM_GIT=$(git -C "$DLM_REPO" rev-parse --show-toplevel) \
		|| { echo "ERROR: DLM_REPO is not a git checkout: $DLM_REPO"; exit 1; }
	REV=$(git -C "$DLM_GIT" rev-parse --verify "$DLM_REV^{commit}") \
		|| { echo "ERROR: $DLM_REV is not a commit in $DLM_GIT"; exit 1; }
	for DLM_PFX in "$(git -C "$DLM_REPO" rev-parse --show-prefix)" ""; do
		git -C "$DLM_GIT" cat-file -e "$REV:${DLM_PFX}core/series" 2>/dev/null && break
		DLM_PFX=none
	done
	[ "$DLM_PFX" != none ] \
		|| { echo "ERROR: $DLM_REV has no core/series (neither under $DLM_REPO nor at the top)"; exit 1; }
	DLM_STRIP=$(printf '%s' "$DLM_PFX" | tr -cd / | wc -c)
}

# git archive of the named core paths at REV, each under DLM_PFX
dlm_archive() {
	_da=
	for _p; do _da="$_da ${DLM_PFX}$_p"; done
	git -C "$DLM_GIT" archive "$REV" $_da
}
