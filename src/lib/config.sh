# shellcheck shell=bash
# Tools and the fixed lists of names and types every snapshot uses.

PUBLIC_RESOLVER="${PUBLIC_RESOLVER:-1.1.1.1}"

DIG="$(command -v dig)"
for candidate in /opt/homebrew/opt/bind/bin/dig /usr/local/opt/bind/bin/dig; do
    if [ -x "$candidate" ]; then DIG="$candidate"; break; fi
done
if [ -z "$DIG" ]; then
    echo "dnsnap: dig not found" >&2
    exit 1
fi
DIG_OPTS=(+time=3 +tries=2)

# delv validates locally against the IANA root trust anchor. The macOS system
# build has no crypto support and refuses every zone, so prefer Homebrew's.
DELV="$(command -v delv)"
for candidate in /opt/homebrew/opt/bind/bin/delv /usr/local/opt/bind/bin/delv; do
    if [ -x "$candidate" ]; then DELV="$candidate"; break; fi
done

# Optional: turns an internationalised name into punycode.
IDN2="$(command -v idn2)"

# The apex's own records, one file per type, in _apex/. CDS/CDNSKEY are here
# and DS is not; RRSIG (type 46) is deliberately absent. README.md says why.
PRIMARY_TYPES="A:1 AAAA:28 CNAME:5 MX:15 NS:2 TXT:16 CAA:257 SOA:6 SRV:33 NAPTR:35 TLSA:52 SSHFP:44 DNSKEY:48 CDS:59 CDNSKEY:60 HTTPS:65 SVCB:64"

# What the parent publishes about this domain, filed apart from _apex/.
PARENT_TYPES="NS:2 DS:43"

# Swept into one file, so the types nobody publishes stay covered without
# turning _apex/ into a wall of empty files.
EXTRA_TYPES="PTR:12 HINFO:13 RP:17 AFSDB:18 LOC:29 KX:36 CERT:37 DNAME:39 APL:42 IPSECKEY:45 NSEC:47 DHCID:49 NSEC3PARAM:51 SMIMEA:53 HIP:55 OPENPGPKEY:61 CSYNC:62 ZONEMD:63 SPF:99 EUI48:108 EUI64:109 URI:256"

# Names a protocol defines rather than names someone chose, so they are worth
# asking about even when this repo has never seen them. The rest of the list
# comes from src/lib/discover.sh.
WELL_KNOWN_NAMES="www mail autodiscover autoconfig mta-sts _mta-sts _smtp._tls _dmarc _domainkey _acme-challenge _domainconnect _autodiscover._tcp _submission._tcp _submissions._tcp _imaps._tcp _pop3s._tcp _caldavs._tcp _carddavs._tcp _sip._tls _sipfederationtls._tcp _xmpp-client._tcp _xmpp-server._tcp _25._tcp _443._tcp"

# Two lists: an underscore name hangs a policy or points at a service and is
# never a host, so asking it for an address only ever comes back empty. TLSA
# is the other way round: it lives under _443._tcp and nowhere else.
NAME_TYPES="A:1 AAAA:28 CNAME:5 MX:15 TXT:16 CAA:257 HTTPS:65 SRV:33"
UNDERSCORE_NAME_TYPES="CNAME:5 TXT:16 SRV:33 TLSA:52"

# The directories dnsnap owns. Every one is underscored, which a DNS label
# cannot be, so the subdirectories that are themselves domains stay
# unambiguous.
NAMES_DIR="_names"
APEX_DIR="_apex"
PARENT_DIR="_parent"
PROBES_DIR="_probes"

# The one file dnsnap reads and never writes; see src/lib/seed.sh.
SEED_FILE="_seed.dns"

# A label asked for on purpose so that it will not be found. Fixed rather than
# randomised per run (which is what DNSViz does, to get past resolver caches):
# this query goes straight to the authoritative server, so a random label would
# rewrite the file every run for no reason.
NXDOMAIN_PROBE="does-not-exist-query-sh"
