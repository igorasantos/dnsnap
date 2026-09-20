#!/usr/bin/env bash
#
# dnsnap: snapshot the publicly visible DNS + registry state of a domain.
#
#   dnsnap <dest>                    refresh every domain already in <dest>
#   dnsnap <dest> example.com        refresh one domain
#   dnsnap <dest> a.com sub.b.co.uk  refresh several
#
# This file is the source template, not a runnable program: `make` splices
# src/lib/ in between the sentinels below to produce dist/dnsnap. See README.md.

# In this file the code below the loader is unreachable and the variables
# shared with src/lib/ look unassigned. Both stop being true once src/lib/ is spliced
# in, and `make check` lints that bundle.
# shellcheck disable=SC2317,SC2329,SC2034

set -o pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# The first argument, and only the first, is the destination directory.
if [ $# -eq 0 ]; then
    echo "dnsnap: usage: $0 <dest-dir> [domain ...]" >&2
    exit 1
fi
DEST_DIR="$1"
shift
if ! mkdir -p "$DEST_DIR" 2>/dev/null; then
    echo "dnsnap: cannot create destination directory '$DEST_DIR'" >&2
    exit 1
fi
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
if [ "$DEST_DIR" = "$SELF_DIR" ]; then
    echo "dnsnap: the destination directory may not be the script's own directory ($SELF_DIR)" >&2
    exit 1
fi
# The label tree starts at the destination directory itself; src/lib/ reads it
# under this name.
QUERIED_DIR="$DEST_DIR"
PUBLIC_RESOLVER="${PUBLIC_RESOLVER:-1.1.1.1}"

# `make` replaces everything between the two sentinels with src/lib/*.sh, in the
# order the Makefile lists. Each module holds one query; its snapshot_*
# function prints one output file to stdout and snapshot() places it.
# @BUNDLE-BEGIN
echo "dnsnap: this is the source template and cannot run on its own." >&2
echo "dnsnap: build and run it with:  make run ARGS='$DEST_DIR $*'" >&2
exit 1
# @BUNDLE-END

snapshot() {
    domain="$1"
    domdir="$(domain_dir "$domain")"
    outdir="$QUERIED_DIR/$domdir"
    # A total failure leaves the previous files alone, but a domain that has
    # never been read leaves nothing at all; see below.
    first_time=""
    [ -d "$outdir" ] || first_time="yes"
    mkdir -p "$outdir"
    ensure_seed_file

    # Where a failed query leaves its note. ask() runs inside $(...), so this
    # cannot be a variable; see src/lib/dig.sh.
    QUERY_FAIL_FILE="$(mktemp "${TMPDIR:-/tmp}/dnsnap.fail.XXXXXX")"

    # Finding the NS set needs recursion, which the domain's own servers will
    # not do, so this one goes to $PUBLIC_RESOLVER.
    # +short prints its errors on stdout, so the output is kept only where it
    # looks like a hostname: without the grep a timeout becomes a nameserver
    # called ";;" and every word of the message becomes another one.
    nameservers="$("$DIG" @"$PUBLIC_RESOLVER" +short -t NS -q "$domain" "${DIG_OPTS[@]}" 2>/dev/null \
                     | grep -E '^[A-Za-z0-9_.-]+\.$' \
                     | sed 's/\.$//' | LC_ALL=C sort)"
    # The first server that answers for the zone serves the whole run, so
    # every file comes from one source and one flaky server does not decide
    # the snapshot.
    AUTH_NS=""
    for ns in $nameservers; do
        if [ -n "$("$DIG" @"$ns" -t TYPE6 -q "$domain" +noall +answer +norecurse \
                         "${DIG_OPTS[@]}" 2>/dev/null)" ]; then
            AUTH_NS="$ns"
            break
        fi
        echo "  ! $ns did not answer for $domain" >&2
    done

    # Nothing authoritative answered, and there is no second-best source to
    # read instead: the records on disk are left exactly as they are.
    if [ -z "$AUTH_NS" ]; then
        if [ -n "$nameservers" ]; then
            fail_reason="no nameserver for $domain answered ($(printf '%s' "$nameservers" | tr '\n' ' '))"
        else
            fail_reason="no NS records for $domain from $PUBLIC_RESOLVER"
        fi
        source_desc="nothing answered"
        rm -f "$QUERY_FAIL_FILE"
        if [ -n "$first_time" ]; then
            # rmdir -p walks back up the label tree and stops at the first
            # directory that is not empty, so a sibling domain is untouched.
            echo "  ! $fail_reason, nothing written" >&2
            rm -f "$(seed_file_path)"
            (cd "$QUERIED_DIR" && rmdir -p "$domdir" 2>/dev/null)
            return 1
        fi
        echo "  ! $fail_reason; snapshot not taken, previous files kept" >&2
        snapshot_failed_meta > "$outdir/_meta.dns"
        return 1
    fi
    source_desc="$AUTH_NS (authoritative)"
    echo "  source: $source_desc"

    # Found once and reused: $PARENT_DIR/ and the DS block of dnssec.dns
    # both ask it.
    PARENT_NS="$(parent_ns "$domain")"

    # From here on an unanswered query is recorded and stepped over; see
    # src/lib/dig.sh.
    snapshot_types
    # snapshot_types made $APEX_DIR. `_extra` is a name no record type can
    # take.
    snapshot_extra_types  > "$outdir/$APEX_DIR/_extra.dns"
    snapshot_parent
    # discover_names reads the files in $outdir, _names/ among them, so the
    # list is taken before snapshot_names starts rewriting them.
    NAMES="$(discover_names "$domain")"
    snapshot_names
    mkdir -p "$outdir/$PROBES_DIR"
    snapshot_nameservers  > "$outdir/$PROBES_DIR/nameservers.dns"
    # reverse reads the A/AAAA/names files written just above
    snapshot_reverse      > "$outdir/$PROBES_DIR/reverse.dns"
    snapshot_dnssec       > "$outdir/$PROBES_DIR/dnssec.dns"
    snapshot_negative     > "$outdir/$PROBES_DIR/negative.dns"
    snapshot_any          > "$outdir/$PROBES_DIR/any.dns"
    snapshot_trace        > "$outdir/$PROBES_DIR/trace.dns"
    # Registry services, not DNS: their outages are recorded in $rdap_note and
    # $whois_note rather than counting as unanswered queries.
    snapshot_rdap
    snapshot_whois
    # Reports both notes above and the failed queries, so it goes last.
    snapshot_meta         > "$outdir/_meta.dns"
    report_query_failures
    if query_failed; then incomplete="yes"; else incomplete=""; fi
    rm -f "$QUERY_FAIL_FILE"
    [ -z "$incomplete" ]
}

# With no domain named, every domain already in $QUERIED_DIR, found by the
# _meta.dns each snapshot leaves behind, read back out of the path it sits in.
domains="$*"
if [ -z "$domains" ]; then
    domains="$(cd "$QUERIED_DIR" 2>/dev/null && find . -type f -name _meta.dns 2>/dev/null \
                 | sed -e 's|^\./||' -e 's|/_meta\.dns$||' \
                 | while read -r dir; do dir_domain "$dir"; echo; done \
                 | LC_ALL=C sort)"
fi
if [ -z "$domains" ]; then
    echo "dnsnap: nothing snapshotted in $QUERIED_DIR yet; name a domain, e.g. $0 $DEST_DIR example.com" >&2
    exit 1
fi

done_any=""
for raw in $domains; do
    domain="$(normalize_domain "$raw")"
    if ! valid_domain "$domain"; then
        echo "dnsnap: '$raw' does not look like a domain, skipped" >&2
        continue
    fi
    echo "$domain"
    if snapshot "$domain"; then
        done_any="yes"
    else
        failed="$failed $domain"
    fi
done

# "incomplete" covers both shapes of failure: nothing read at all, and some
# queries unanswered. Each _meta.dns says which it was.
if [ -n "$failed" ]; then
    echo "dnsnap: incomplete:$failed" >&2
fi
if [ -z "$done_any" ]; then
    exit 1
fi
