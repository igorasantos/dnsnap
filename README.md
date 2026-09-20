# dnsnap

Version control for public DNS records you need to keep. dnsnap snapshots a domain's publicly visible DNS and registry state into a directory of plain text files, so `git diff` tells you exactly what changed on a client's zone, and when.

```bash
make
./dist/dnsnap ./snapshots example.com
```

```
<dest>/
└── com/
    └── example/
        ├── _apex/          A.dns  AAAA.dns  MX.dns  TXT.dns  DNSKEY.dns  _extra.dns  ...
        ├── _parent/        NS.dns  DS.dns  _glue.dns
        ├── _names/         www.dns  _dmarc.dns  _tcp/_443.dns  ...
        ├── _probes/        nameservers.dns  negative.dns  dnssec.dns  trace.dns  any.dns  reverse.dns
        ├── _seed.dns      <- yours; dnsnap reads it and never writes it
        ├── rdap.json
        ├── whois.dns
        └── _meta.dns
```

`.dns` is not a standardised file format or extension. The files are plain text, mostly `dig` output in master-file (zone-file) form, and the extension was adopted purely as dnsnap's internal convention, to mark the files that belong to a snapshot. Nothing else reads it: no resolver, no nameserver and no registry knows about `.dns`, and the files are not meant to be loaded into a server as a zone.

## Why

DNS has no undo and no history. A record is changed in a provider's web UI and the previous value is simply gone, along with the answer to "was it like this last week?". Monitoring tools watch a handful of names you remembered to enter; they do not give you the zone as a file you can read, diff and keep.

dnsnap writes the whole public picture to disk in a form built for version control:

- **Queries go to the domain's own authoritative nameserver**, not a resolver, so the TTLs and record sets are the published ones, not whatever a cache happens to hold. There is no fallback to the machine's own resolver: a cache is not the published zone, and there is no second-best source worth writing to a file.
- **Per-run noise is stripped** (query time, answering server, timestamp, message id) and record lines are sorted, because servers rotate record sets between answers. A file only moves when DNS moves. The deliberate exceptions: `SOA` (serial), `rdap.json` (the registry stamps its own update time) and `_meta.dns`.
- **Nothing comes from a provider account.** Everything in the output is what anyone can look up with `dig`, `curl` and `whois`.

Commit the destination directory and the history of your domains becomes `git log`.

## The layout

Labels become directories, in reverse, so the tree mirrors the DNS hierarchy and a domain sits inside its own parent:

| domain | directory |
|---|---|
| `example.dev` | `dev/example/` |
| `api.example.dev` | `dev/example/api/` |
| `shop.example.co.uk` | `uk/co/example/shop/` |

Every directory is a DNS label except the underscore ones, which are dnsnap's: a label can never collide with them.

**`_apex/`**: the zone's own records, one file per type, read from its own servers. The twenty-odd types almost nobody publishes are swept into a single `_extra.dns` instead, so covering them does not turn the directory into a wall of empty files.

**`_parent/`**: the delegation, read from a server authoritative for the *parent*: the NS set the parent hands out, the DS that signs the referral, and glue addresses for nameservers living inside the zone.

The split matters. These two are answered by different people (the DNS operator and whoever holds the registration), and they disagree more often than they should: an NS removed at the registrar but still in the zone, a DS left behind after a key was retired. A record only means what it means once you know which side published it. It is also why `CDS`/`CDNSKEY` sit in `_apex/` while `DS` sits in `_parent/`: the diff between them *is* a key rollover in progress.

**`_names/`**: the names below the apex, one file per name holding every type it answers for. (The apex asks "what does this zone publish?", a name below it asks "what is this name *for*?": different questions, different shapes.) Middle labels stay directories, so `_443._tcp.example.dev` is `_names/_tcp/_443.dns` and every service under `_tcp` lines up side by side.

**`_probes/`**: the queries that are not about a record but about *behaviour*: the name sent in mixed case (DNS 0x20) and a DNS cookie query to each nameserver; a name that does not exist and a type the apex cannot hold. What a zone says when it has nothing to say is where negative caching, wildcards and the NSEC/NSEC3 proofs become visible. Also the root trace, `ANY`, reverse lookups, and the DNSSEC chain read from both sides at once.

The label that is meant not to exist is a fixed one, not randomised per run the way DNSViz randomises it to get past resolver caches: these queries go straight to the authoritative server, so a fresh label each time would rewrite the file for no reason.

## `_seed.dns`, and the thing DNS will not tell you

dnsnap works out which names to ask about from the last snapshot (the files in `_names/`, the records already committed, the subdirectories) plus the handful of names a protocol defines (`_dmarc`, `_mta-sts`, `_25._tcp`, ...).

That is *memory*, not a source. DNS will not hand back a list of the names in a zone, so a chosen label nobody points at (`api`, `pop`, a DKIM selector) is gone for good once its file is.

`_seed.dns` is the one file in a domain's directory that is yours. dnsnap creates it once, holding nothing but a comment explaining what it is for, reads it on every run, and never writes to it again. One name per line, relative to the apex or spelled out in full; `;` and `#` start a comment and blank lines are ignored:

```
api
sig1._domainkey
pop.example.com.
```

## Usage

```bash
dnsnap <dest>                      # refresh every domain already in <dest>
dnsnap <dest> example.com          # snapshot one domain
dnsnap <dest> a.com sub.b.co.uk    # several
```

`<dest>` is any directory you like. `.` writes into the directory you are standing in, which is the usual thing to do from inside the git repo that keeps the snapshots:

```bash
cd ~/my-dns-repo && dnsnap . example.com
```

The first argument is always the destination directory. It is created if missing, and it may not be the directory the running script itself lives in, so a checkout of this repo cannot be snapshotted over its own `dist/`. Domains are taken however you paste them: scheme, credentials, port, path, trailing dot and upper case are all stripped, and an internationalised name becomes punycode when `idn2` is installed.

With no domains named, every domain already in `<dest>` is refreshed, found by the `_meta.dns` each snapshot leaves behind.

| variable | default | |
|---|---|---|
| `PUBLIC_RESOLVER` | `1.1.1.1` | every query that needs recursion, which a nameserver authoritative for the domain will not do: finding the domain's NS set, resolving those nameservers' own names to addresses, the `PTR` lookups behind `reverse.dns`, bootstrapping `+trace` from the root, finding the parent zone's servers and reading `DS` from them, and asking a validating resolver whether DNSSEC checks out |

The machine's own resolver is never queried, for anything. `PUBLIC_RESOLVER` is a named server that is the same everywhere; `/etc/resolv.conf` is whatever the network you happen to be on decided, and it answers from a cache.

## When a server does not answer

A timeout, a `SERVFAIL` or a refusal is not a record set. Writing a file from that silence produces something indistinguishable from a domain that genuinely publishes nothing: commit it and the history records a deletion that never happened. So dnsnap treats it as a failure rather than as data:

- Every nameserver in the NS set is tried, in order, and **the first one that answers serves the whole run**. One flaky server no longer decides the snapshot, and every file still comes from a single source.
- If **none** of them answers, no record file is touched. Only `_meta.dns` is rewritten, saying what was tried and when, and the previous snapshot stays exactly as it was on disk.
- If a query fails **during** a snapshot, the snapshot carries on without it. It cost the run the one record set that query was asking about, not the other forty: the file for it says `QUERY FAILED` instead of `no records published`, `_meta.dns` opens with an `INCOMPLETE` block listing every query that went unanswered, and the exit status says so. A server that refuses a single record type does not take the whole domain with it.
- There is **no `_apex/RRSIG.dns`**. A signature belongs to the RRset it signs, not to a file of its own, and a zone signed on the fly cannot answer for it: Cloudflare replies `REFUSED` with `EDE 21: RRSIG queries not supported here`. A server that does answer hands back an empty `NOERROR` for a zone that is demonstrably signed, which reads as "unsigned" and is worse. `_probes/dnssec.dns` is where the signing is recorded.
- A `REFUSED` or `SERVFAIL` that arrives with an [Extended DNS Error](https://www.rfc-editor.org/rfc/rfc8914.html) records the server's own reason alongside the status, so `_meta.dns` says `answered REFUSED (EDE 21: RRSIG queries not supported here)` rather than leaving a bare status to be investigated.
- An answer that is **empty** is not a failure. `NOERROR` with no records means the zone was asked and had nothing to say, and the `NXDOMAIN` the probes go looking for is the point of `_probes/`. Both are recorded as always.
- The delegation in `_parent/` is read from a server authoritative for the parent and from nowhere else. A `DS` out of a cache is not the `DS` the registry publishes, and its TTL would count down between runs; no answer there is a failure like any other.
- A domain that has **never** been snapshotted and fails on its first run leaves nothing behind: no directory, no `_seed.dns`, no `_meta.dns`. A directory whose only content is the record of a failure is not worth committing. Domains already on disk keep their files and get the failure written to `_meta.dns`.

- **RDAP and whois are not DNS.** They are registry services with their own outages and rate limits, so a failure there never marks a snapshot incomplete: `rdap.json` and `whois.dns` keep their previous contents and `_meta.dns` records what happened on its `rdap:` and `whois:` lines.

The exit status is non-zero when no domain could be snapshotted at all; domains that failed, whether nothing was read for them or some of their queries went unanswered, are listed on stderr as `incomplete`, so a run of many domains where some are down still succeeds.

## Install

```bash
brew trust --formula igorasantos/tap/dnsnap
brew install igorasantos/tap/dnsnap
```

### From source

```bash
make            # builds dist/dnsnap, a single self-contained script
make install    # PREFIX=/usr/local by default
```

`dist/dnsnap` needs neither `make` nor `src/lib/` at runtime; copy it anywhere.

**Requires** `bash` and `dig`. **Recommended:** a modern BIND (`brew install bind`). The macOS system `dig` (9.10) does not know `HTTPS`/`SVCB`/`ZONEMD` and silently answers an `A` query when handed those names, which is why every lookup here is made by numeric type (`TYPE65`, ...). Old `dig` then prints RFC 3597 `\# len hex` rdata, and the file says so. dnsnap picks up a Homebrew `dig`/`delv` on its own. **Optional:** `curl` + `jq` for RDAP, `whois`, `delv` for local DNSSEC validation, `idn2` for internationalised names.

## Development

`src/dnsnap.sh` is a source template, not a runnable program: run it and it says so. `make` splices `src/lib/*.sh` into it between the two sentinels to produce `dist/dnsnap`, which is the command. `dist/` is not committed.

```bash
make audit    # fails when MODULES and src/lib/*.sh disagree
make check    # audit + shellcheck (on dist/dnsnap, see below)
make run ARGS='/tmp/snap example.com'
make -s print-modules
```

`shellcheck` runs on `dist/dnsnap`, not on `src/lib/*.sh` one by one. Each module is a fragment that only becomes a valid script once concatenated: read alone, every variable it shares with the others looks unassigned or unused. The bundle contains every line of `src/lib/`, so linting it covers them and the findings are real ones. The `# shellcheck shell=bash` at the top of each module is there for editors and for anyone linting a single file by hand.

The module list and its load order live in the `Makefile` and nowhere else. One module per query; each `snapshot_*` function prints one output file to stdout and `snapshot()` decides where it goes.
