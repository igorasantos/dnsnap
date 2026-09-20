# shellcheck shell=bash
# The hand-kept list of names to ask about (_seed.dns): the one source of names
# that does not depend on the last snapshot. See README.md.
#
# One name per line, relative to the apex or spelled out in full. ';' and '#'
# start a comment; blank lines are ignored.

seed_file_path() {
    printf '%s/%s' "$outdir" "$SEED_FILE"
}

# Written once, holding nothing but the explanation of what it is for, and
# never rewritten: a run that overwrote it would turn it back into output.
ensure_seed_file() {
    seed_file="$(seed_file_path)"
    [ -e "$seed_file" ] && return 0
    {
        cmt "$domain: names to always ask about"
        cmt ""
        cmt "This file is yours: dnsnap reads it and never writes it."
        cmt ""
        cmt "Every other name it asks about is discovered from the last"
        cmt "snapshot. DNS cannot be asked for the names in a zone, so a label"
        cmt "nobody points at (api, pop, a DKIM selector) is found again"
        cmt "only if it is written down here."
        cmt ""
        cmt "One name per line, relative to the apex or spelled out in full:"
        cmt ""
        cmt "  api"
        cmt "  sig1._domainkey"
        cmt "  pop.$domain."
    } > "$seed_file"
}

# The names in it, each one made absolute. Unreadable or missing is the same
# as empty.
seed_names() {
    seed_file="$(seed_file_path)"
    [ -r "$seed_file" ] || return 0
    sed -e 's/[;#].*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$seed_file" \
        | grep -v '^$' \
        | while read -r name; do
              case "$name" in
                  *".$domain"|*".$domain.") printf '%s\n' "$name" ;;
                  "$domain"|"$domain.")     ;;
                  *)                        printf '%s.%s\n' "$name" "$domain" ;;
              esac
          done
}
