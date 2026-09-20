# shellcheck shell=bash
# Snapshot metadata (_meta.dns).

snapshot_meta() {
    cmt "$domain: snapshot metadata"
    cmt ""
    cmt "taken:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    cmt "dig:         $("$DIG" -v 2>&1 | head -1)"
    cmt "queried:     $source_desc"
    cmt "nameservers: $(printf '%s' "$nameservers" | tr '\n' ' ')"
    cmt "resolver:    $PUBLIC_RESOLVER (NS discovery, NS addresses, reverse, trace, DS, validation)"
    cmt "rdap:        $rdap_note"
    cmt "whois:       $whois_note"
    cmt ""
    snapshot_meta_failures
    cmt "Everything in this directory is public: it was read out of DNS and"
    cmt "the registry, never out of a provider account. This is the only file"
    cmt "that changes on every run."
}

# The queries that went unanswered. Each also left a QUERY FAILED banner in the
# file it was for, but those are scattered; this is the one place that says how
# much of the snapshot is missing.
snapshot_meta_failures() {
    query_failed || return 0
    count="$(query_failure_count)"
    cmt "INCOMPLETE: $count quer$([ "$count" = 1 ] && echo y || echo ies) went unanswered:"
    query_failure_reason | while IFS= read -r line; do cmt "  $line"; done
    cmt ""
    cmt "Everything else here was read by this run. The file each failed query"
    cmt "was for says QUERY FAILED in place of records, which is not the same"
    cmt "as an empty record set and must not be read as one."
    cmt ""
}

# Written when no authoritative server answered at all, so no query was made
# and no record file touched. A run that got answers writes snapshot_meta
# above instead, failures and all: a partial snapshot is still a snapshot.
snapshot_failed_meta() {
    cmt "$domain: snapshot FAILED"
    cmt ""
    cmt "attempted:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    cmt "dig:         $("$DIG" -v 2>&1 | head -1)"
    cmt "failure:     $fail_reason"
    cmt "nameservers: $(printf '%s' "$nameservers" | tr '\n' ' ')"
    cmt "resolver:    $PUBLIC_RESOLVER (NS discovery, NS addresses, reverse, trace, DS, validation)"
    cmt ""
    cmt "No record file here was written by that run: what is in them is"
    cmt "whatever the last run that got answers left behind, and it may now"
    cmt "be out of date."
    cmt ""
    cmt "dnsnap does not fall back to a resolver. A cached answer is not the"
    cmt "published zone, and a file written from silence would read as a"
    cmt "record that was deleted."
}

# On stderr too, so a run being watched does not look clean when it is not.
report_query_failures() {
    query_failed || return 0
    query_failure_reason | while IFS= read -r line; do
        echo "  ! $line" >&2
    done
}
