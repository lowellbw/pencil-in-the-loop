# tooling/Makefile — the compiler substitute.
#
# There is no Swift toolchain on this machine, so nothing in PencilLoopKit can be
# built or tested until it reaches a Mac. These seven checks are what stands
# between six agents writing in parallel and a morning spent on other people's
# compile errors.
#
#   make -C tooling check      run everything, print a summary, fail if any failed
#   make -C tooling imports    (and decls, contracts, style, json, pbxproj, plists)
#
# Every check is Python 3, standard library only, and lists every problem it
# finds rather than stopping at the first.
#
# check_pbxproj.py and check_plists.py belong to W0-A and may not have landed
# yet. A missing script is skipped with a note; a script that exists and fails is
# a failure. Same rule for the trees they inspect.

PYTHON ?= python3
LINT := $(CURDIR)/lint

# W0-B's five, then W0-A's two.
CHECKS := check_imports.py check_decls.py check_contracts.py check_style.py \
          check_json.py check_pbxproj.py check_plists.py

.PHONY: check imports decls contracts style json pbxproj plists list help

check:
	@echo "── make check ─────────────────────────────────────────────────────────"
	@failed=0; skipped=0; ran=0; \
	for script in $(CHECKS); do \
		if [ ! -f "$(LINT)/$$script" ]; then \
			printf "  SKIP  %-22s (not written yet)\n" "$$script"; \
			skipped=$$((skipped+1)); \
			continue; \
		fi; \
		output=$$($(PYTHON) "$(LINT)/$$script" 2>&1); status=$$?; \
		ran=$$((ran+1)); \
		if [ $$status -eq 0 ]; then \
			printf "  PASS  %-22s %s\n" "$$script" "$$(echo "$$output" | tail -n 1)"; \
		else \
			printf "  FAIL  %-22s\n" "$$script"; \
			echo "$$output" | sed 's/^/          /'; \
			failed=$$((failed+1)); \
		fi; \
	done; \
	echo "───────────────────────────────────────────────────────────────────────"; \
	echo "  $$ran run · $$failed failed · $$skipped skipped"; \
	if [ $$failed -ne 0 ]; then \
		echo "  Fix the failures above. Nothing here is advisory."; \
		exit 1; \
	fi; \
	echo "  All checks passed."

imports:
	@$(PYTHON) $(LINT)/check_imports.py

decls:
	@$(PYTHON) $(LINT)/check_decls.py

contracts:
	@$(PYTHON) $(LINT)/check_contracts.py

style:
	@$(PYTHON) $(LINT)/check_style.py

json:
	@$(PYTHON) $(LINT)/check_json.py

pbxproj:
	@if [ -f $(LINT)/check_pbxproj.py ]; then $(PYTHON) $(LINT)/check_pbxproj.py; \
	else echo "check_pbxproj.py not written yet (W0-A)"; fi

plists:
	@if [ -f $(LINT)/check_plists.py ]; then $(PYTHON) $(LINT)/check_plists.py; \
	else echo "check_plists.py not written yet (W0-A)"; fi

list:
	@echo "$(CHECKS)" | tr ' ' '\n'

help:
	@echo "make -C tooling check     every check, with a summary"
	@echo "make -C tooling imports   module import policy (Core: Foundation only)"
	@echo "make -C tooling decls     one declaration per type name, no dangling refs"
	@echo "make -C tooling contracts conformances match the frozen protocols"
	@echo "make -C tooling style     braces, markers, force unwraps, spellings"
	@echo "make -C tooling json      fixtures validate, golden fixtures match the spec"
	@echo "make -C tooling pbxproj   Xcode project sanity (W0-A)"
	@echo "make -C tooling plists    Info.plist sanity (W0-A)"
