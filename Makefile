# The module list and its load order live here and nowhere else: src/lib/*.sh is
# concatenated in this order into the single-file dist/dnsnap.
MODULES := config domain dig seed discover \
           types extra_types parent names nameservers reverse dnssec negative \
           any trace rdap whois meta

LIBS    := $(addprefix src/lib/,$(addsuffix .sh,$(MODULES)))
PREFIX  ?= /usr/local
ARGS    ?=

.PHONY: all build print-modules audit check run install uninstall clean

all: build

# `make -s print-modules` keeps the output bare, for scripting.
print-modules:
	@echo $(MODULES)

# Everything up to @BUNDLE-BEGIN, then the modules inline, then everything from
# @BUNDLE-END on, so dist/dnsnap needs neither make nor src/lib/ at runtime.
build: src/dnsnap.sh $(LIBS) Makefile
	@mkdir -p dist
	@sed '/^# @BUNDLE-BEGIN$$/,$$d' src/dnsnap.sh > dist/dnsnap
	@for m in $(MODULES); do \
	    printf '\n# ---- src/lib/%s.sh ----\n' "$$m"; \
	    sed -e '/^#!/d' "src/lib/$$m.sh"; \
	done >> dist/dnsnap
	@sed -n '/^# @BUNDLE-END$$/,$$p' src/dnsnap.sh | tail -n +2 >> dist/dnsnap
	@chmod +x dist/dnsnap
	@bash -n dist/dnsnap
	@echo "built dist/dnsnap ($$(wc -l < dist/dnsnap | tr -d ' ') lines)"

# Without this a new module could be dropped in src/lib/, forgotten in MODULES,
# and silently left out of the bundle.
audit: | dist
	@ls src/lib/*.sh | sed -e 's|^src/lib/||' -e 's|\.sh$$||' | sort > dist/.have
	@printf '%s\n' $(MODULES) | sort > dist/.want
	@diff -u dist/.want dist/.have > dist/.diff \
	    || { echo 'MODULES vs src/lib/*.sh disagree (- only in MODULES, + only in src/lib/):' >&2; \
	         sed -n '4,$$p' dist/.diff >&2; exit 1; }
	@echo "modules ok: $(words $(MODULES)) listed, all present in src/lib/"

dist:
	@mkdir -p dist

# src/lib/*.sh is not linted file by file: each is a fragment that only becomes a
# valid script once concatenated. dist/dnsnap contains every line of src/lib/, so
# linting it covers them for real.
check: audit build
	shellcheck src/dnsnap.sh dist/dnsnap

# make run ARGS='/tmp/snap example.com'
run: build
	@./dist/dnsnap $(ARGS)

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 dist/dnsnap $(DESTDIR)$(PREFIX)/bin/dnsnap

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/dnsnap

clean:
	rm -rf dist
