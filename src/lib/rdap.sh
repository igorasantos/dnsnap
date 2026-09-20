# shellcheck shell=bash
# Registry RDAP record (rdap.json). Sets rdap_note.

snapshot_rdap() {
# jq -S sorts the keys, so two snapshots of an unchanged registration diff
# clean whatever order the server serialised in. Neither tool is worth a hard
# dependency, but a missing one has to say so: otherwise it is indistinguishable
# from the registry being down.
missing=""
command -v curl >/dev/null 2>&1 || missing="curl"
command -v jq   >/dev/null 2>&1 || missing="${missing:+$missing and }jq"
if [ -n "$missing" ]; then
    rdap_note="not attempted ($missing not installed)"
    echo "  ! $missing not installed, skipped RDAP" >&2
    return
fi

tmp="$outdir/.rdap.$$"
if curl -fsSL --max-time 20 "https://rdap.org/domain/$domain" 2>/dev/null | jq -S . > "$tmp" 2>/dev/null \
   && [ -s "$tmp" ]; then
    mv "$tmp" "$outdir/rdap.json"
    rdap_note="ok"
else
    rm -f "$tmp"
    rdap_note="failed (previous rdap.json kept)"
    echo "  ! RDAP lookup failed, kept the previous rdap.json" >&2
fi
}
