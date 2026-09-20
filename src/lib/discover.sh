# shellcheck shell=bash
# Finding the names to query below the apex.

# Every name under <domain> this repo knows about: the owner names in the last
# snapshot, the right-hand side of its records, the subdirectories, the
# protocol-defined names, and _seed.dns. All but the last are memory of a
# previous run; see src/lib/seed.sh.
discover_names() {
    domain="$1"
    domdir="$(domain_dir "$domain")"
    escaped="$(printf '%s' "$domain" | sed 's/\./\\./g')"
    {
        {
            # -maxdepth 1: a subdomain's own snapshot sits below this one and
            # is not part of this domain's files. It turns up as a directory
            # further down.
            find "$QUERIED_DIR/$domdir" -maxdepth 1 -type f -name '*.dns' \
                 -exec cat {} + 2>/dev/null

            # _probes/ names hosts too. negative.dns is skipped on purpose:
            # its owner names are the probe label and, in an NSEC3 zone,
            # hashes. Feeding those back in would query them forever and file
            # them as if they were real.
            find "$QUERIED_DIR/$domdir/$PROBES_DIR" -maxdepth 1 -type f -name '*.dns' \
                 ! -name 'negative.dns' -exec cat {} + 2>/dev/null

            # Any apex record can name a subdomain, and the delegation's NS
            # set often names hosts inside this very zone.
            find "$QUERIED_DIR/$domdir/$APEX_DIR" "$QUERIED_DIR/$domdir/$PARENT_DIR" \
                 -maxdepth 1 -type f -name '*.dns' -exec cat {} + 2>/dev/null

            # The whole of _names/, however deep its grouping directories go.
            find "$QUERIED_DIR/$domdir/$NAMES_DIR" -type f -name '*.dns' \
                 -exec cat {} + 2>/dev/null
        } | awk '
            # A record line is <owner> <ttl> IN <type> <rdata...>. The owner
            # is taken from all of them, the rdata only from the types whose
            # rdata is a domain name, so a hostname inside an SPF or DKIM TXT
            # string is not mistaken for one.
            $1 ~ /^[A-Za-z0-9_*.-]+\.?$/ && $2 ~ /^[0-9]+$/ && $3 == "IN" {
                print $1
                if ($4 == "CNAME" || $4 == "DNAME" || $4 == "NS" || $4 == "PTR") print $5
                else if ($4 == "MX") print $6
                else if ($4 == "SRV") print $8
            }'

        # The file names in _names/, so that a name whose file holds nothing
        # but ";; no records published" keeps being asked about. The path below
        # _names/ is the name with its labels reversed, so dir_domain turns it
        # back into one.
        find "$QUERIED_DIR/$domdir/$NAMES_DIR" -type f -name '*.dns' 2>/dev/null \
            | while read -r name_file; do
                  rel="${name_file#"$QUERIED_DIR/$domdir/$NAMES_DIR/"}"
                  printf '%s.%s\n' "$(dir_domain "${rel%.dns}")" "$domain"
              done

        # A subdomain snapshotted in its own right: the directory is the name.
        # dnsnap's own directories are pruned: none of them is a domain, and a
        # subdomain further down has ones of its own.
        find "$QUERIED_DIR/$domdir" -mindepth 1 \
             \( -name "$NAMES_DIR" -o -name "$APEX_DIR" -o -name "$PARENT_DIR" \
                -o -name "$PROBES_DIR" \) -prune \
             -o -type d -print 2>/dev/null \
            | sed "s|^$QUERIED_DIR/||" \
            | while read -r subdir; do dir_domain "$subdir"; echo; done

        for prefix in $WELL_KNOWN_NAMES; do
            printf '%s.%s\n' "$prefix" "$domain"
        done

        seed_names
    } | sed 's/\.$//' \
      | grep -E "\.$escaped\$" \
      | grep -Ev '[*]|[^A-Za-z0-9_.-]' \
      | LC_ALL=C sort -u
}
