# shellcheck shell=bash
# Helpers shared by every query: asking dig, and normalising what comes back.

cmt() {
    if [ -z "$1" ]; then printf ';;\n'; else printf ';; %s\n' "$1"; fi
}

# Answer records only, sorted: servers rotate A/AAAA sets between answers.
# awk, not grep: grep exits 1 when it matches nothing, and under pipefail that
# would turn a zone with no records of this type into a failed query, the
# exact confusion the failure handling exists to prevent.
records() {
    awk '!/^;/ && !/^[[:space:]]*$/' | LC_ALL=C sort -u
}

# Drop the lines that differ on every run for reasons that are not DNS.
strip_noise() {
    sed -e '/^; <<>> DiG/d' \
        -e '/^; ([0-9]* server[s]* found)/d' \
        -e '/^;; global options:/d' \
        -e '/^;; Got answer:/d' \
        -e '/^; COOKIE:/d' \
        -e '/^;; Query time:/d' \
        -e '/^;; SERVER:/d' \
        -e '/^;; WHEN:/d' \
        -e '/^;; MSG SIZE/d' \
        -e 's/, id: [0-9][0-9]*$//'
}

# Sort each run of record lines on its own, leaving the ';' headers and the
# blank lines that delimit them in place.
sort_sections() {
    awk 'function flush(   i, j, t) {
             for (i = 0; i < n; i++)
                 for (j = i + 1; j < n; j++)
                     if (buf[j] < buf[i]) { t = buf[i]; buf[i] = buf[j]; buf[j] = t }
             for (i = 0; i < n; i++) print buf[i]
             n = 0
         }
         /^;/ || /^[[:space:]]*$/ { flush(); print; next }
         { buf[n++] = $0 }
         END { flush() }'
}

# A query that did not come back. A timeout, a REFUSED or a SERVFAIL is not a
# record set, so it is recorded as a failure rather than written to a file as
# if the zone had published nothing; an empty NOERROR is the opposite and is
# recorded as always. README.md has the reasoning.
#
# Each failure is appended here and the run carries on: _meta.dns lists them
# all at the end and the file each one was for carries a QUERY FAILED banner.
# The list lives in a file because ask() runs inside $(...), and a subshell
# cannot set a variable its caller will ever see.
note_query_failure() {
    # One unreachable server produces the same line for every query that
    # follows it.
    grep -qxF "$1" "$QUERY_FAIL_FILE" 2>/dev/null && return 0
    printf '%s\n' "$1" >> "$QUERY_FAIL_FILE"
}

query_failed() { [ -s "$QUERY_FAIL_FILE" ]; }

query_failure_reason() { cat "$QUERY_FAIL_FILE" 2>/dev/null; }

query_failure_count() { grep -c . "$QUERY_FAIL_FILE" 2>/dev/null || echo 0; }

# answered <dig-exit-status> <message>. Did the server reply at all? dig exits
# non-zero when nothing came back, but a SERVFAIL or REFUSED reply exits 0 and
# has to be read off the status line, which is why every query below asks for
# +comments even when the caller only wants records.
answered() {
    [ "$1" -eq 0 ] || return 1
    case "$2" in
        *"status: NOERROR"*|*"status: NXDOMAIN"*) return 0 ;;
        *)                                        return 1 ;;
    esac
}

# why_unanswered <dig-exit-status> <message>. The two cases answered() rejects,
# told apart: a server that never spoke wants a retry, one that said REFUSED
# wants a look at its configuration. The status comes off the header line dig
# prints as ";; ->>HEADER<<- ... status: REFUSED, id: 123".
why_unanswered() {
    if [ "$1" -ne 0 ]; then
        printf 'no reply (dig exit %s: timed out or unreachable)' "$1"
        return 0
    fi
    status="$(printf '%s\n' "$2" | sed -n 's/.*status: \([A-Z][A-Z]*\).*/\1/p' | head -1)"
    if [ -n "$status" ]; then
        printf 'answered %s' "$status"
        ede="$(extended_error "$2")"
        [ -n "$ede" ] && printf ' (%s)' "$ede"
    else
        printf 'reply unreadable (no status line)'
    fi
}

# extended_error <message>. The Extended DNS Error (RFC 8914), if the server
# sent one, turning a bare REFUSED into a reason. dig prints it in the OPT
# pseudosection:
#
#   ; EDE: 21 (Not Supported): (RRSIG queries not supported here)
#
# The queries above ask with +noall, which leaves that section out, so it costs
# one extra dig, on the failure path only.
extended_error() {
    line="$(printf '%s\n' "$1" | sed -n '/^; *EDE:/p' | head -1)"
    if [ -z "$line" ] && [ -n "$ede_query_name" ]; then
        line="$("$DIG" @"$AUTH_NS" -t "TYPE$ede_query_type" -q "$ede_query_name" \
                      +norecurse +noall +comments +opt "${DIG_OPTS[@]}" 2>/dev/null \
                  | sed -n '/^; *EDE:/p' | head -1)"
    fi
    [ -n "$line" ] || return 0
    # "; EDE: 21 (Not Supported): (text)" -> "EDE 21: text"
    printf '%s\n' "$line" | sed -e 's/^; *EDE: */EDE /' \
                                 -e 's/ *(\([^)]*\)): *(\(.*\))$/: \2/' \
                                 -e 's/ *(\([^)]*\))$/ \1/' \
                                 -e 's/)$//'
}

# ask <name> <typecode>. Asks the authoritative server chosen for this run.
# There is no resolver to fall back to; see README.md.
ask() {
    ede_query_name="$1"; ede_query_type="$2"
    msg="$("$DIG" @"$AUTH_NS" -t "TYPE$2" -q "$1" +norecurse \
                 +noall +comments +answer "${DIG_OPTS[@]}" 2>/dev/null)"
    rc=$?
    if ! answered "$rc" "$msg"; then
        note_query_failure "$1 TYPE$2: $(why_unanswered "$rc" "$msg") from $AUTH_NS"
        return 1
    fi
    printf '%s\n' "$msg" | sed '/^;/d'   # sed, not grep: see records() above
}

# ask_msg <name> <typecode>. The same query, but the whole message: status,
# flags and the authority section. A negative answer carries nothing in its
# answer section, so ask() above would see nothing at all.
ask_msg() {
    ede_query_name="$1"; ede_query_type="$2"
    msg="$("$DIG" @"$AUTH_NS" -t "TYPE$2" -q "$1" +dnssec +norecurse \
                 +noall +comments +answer +authority "${DIG_OPTS[@]}" 2>/dev/null)"
    rc=$?
    if ! answered "$rc" "$msg"; then
        note_query_failure "$1 TYPE$2: $(why_unanswered "$rc" "$msg") from $AUTH_NS"
        return 1
    fi
    printf '%s\n' "$msg"
}

# An RRSIG carries an inception and an expiry that move on their own schedule,
# so a file keeping them would move every run for reasons that are not the
# zone's. Matched on the type field rather than anywhere on the line: RRSIG
# turns up again inside an NSEC type bitmap, where it is a list entry saying
# "signatures exist here", and dropping that line would throw away the proof
# these files are kept for.
drop_signatures() {
    awk '!($3 == "IN" && $4 == "RRSIG")'
}

negative_view() {
    strip_noise | drop_signatures | sort_sections
}

# example.dev -> ExAmPlE.DeV, for the DNS 0x20 probe. Fixed alternating case
# rather than random, so the file does not move between runs.
mixed_case() {
    printf '%s' "$1" | awk '{
        n = split($0, ch, "")
        out = ""
        for (i = 1; i <= n; i++) out = out (i % 2 ? toupper(ch[i]) : ch[i])
        printf "%s", out
    }'
}
