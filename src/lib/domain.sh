# shellcheck shell=bash
# Turning whatever was typed into a domain, and a domain into a directory.

# example.dev -> dev/example, shop.example.co.uk -> uk/co/example/shop
domain_dir() {
    printf '%s' "$1" | awk -F. '{ for (i = NF; i > 1; i--) printf "%s/", $i; printf "%s", $1 }'
}

# The reverse: dev/example -> example.dev
dir_domain() {
    printf '%s' "$1" | awk -F/ '{ out = $NF; for (i = NF - 1; i > 0; i--) out = out "." $i; printf "%s", out }'
}

# Take the domain however it was pasted: a URL, a trailing dot, upper case.
normalize_domain() {
    normalized="$(printf '%s' "$1" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
              -e 's|^[a-z][a-z0-9+.-]*://||' \
              -e 's|^[^/@]*@||' \
              -e 's|[/?#].*$||' \
              -e 's|:[0-9]*$||' \
              -e 's|^\.*||' -e 's|\.*$||')"
    # Queries and answers carry the punycode form, so file it under that too
    # and the directory matches what is inside the files. Without idn2 the
    # name is used as typed, which still resolves.
    case "$normalized" in
        *[!a-z0-9._-]*)
            if [ -n "$IDN2" ]; then
                normalized="$("$IDN2" "$normalized" 2>/dev/null || printf '%s' "$normalized")"
            fi ;;
    esac
    printf '%s' "$normalized"
}

# Permissive on purpose: underscores (_dmarc), hyphens and non-ASCII labels
# all pass. Requiring a dot is what catches a mistyped argument.
valid_domain() {
    case "$1" in
        ''|*[[:space:]]*|*/*|*..*) return 1 ;;
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}
