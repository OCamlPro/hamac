# SPDX-License-Identifier: AGPL-3.0-only
#
# Documents officiels de Hamac, en Typst. Les PDF se construisent, ils ne se
# versionnent pas : la CI les produit et les publie.
#
#   make -C doc           construit tous les PDF
#   make -C doc check     échoue au moindre avertissement de typst (police
#                         manquante, référence cassée) : la CI rendrait
#                         sinon un autre document que celui de l'auteur.
#                         Le PDF de contrôle s'écrit dans doc/ et non dans
#                         /dev/null ou /tmp, que le typst de snap ne peut
#                         pas atteindre. Seules les lignes « warning: »
#                         de typst comptent (le lanceur snap écrit aussi
#                         des « WARNING » qui ne concernent pas le document).

TYPST     ?= typst
DOCS      := $(basename $(notdir $(filter-out typst/theme.typ,$(wildcard typst/*.typ))))
PDFS      := $(DOCS:%=typst/%.pdf)
SOURCES   := typst/theme.typ $(wildcard assets/*.png assets/logo/*.svg)

all: $(PDFS)

typst/%.pdf: typst/%.typ $(SOURCES)
	$(TYPST) compile --root . $< $@

check:
	@set -e; for d in $(DOCS); do \
	  echo "typst check typst/$$d.typ"; \
	  $(TYPST) compile --root . typst/$$d.typ .check.pdf 2> .typst.log \
	    || { cat .typst.log; rm -f .typst.log .check.pdf; exit 1; }; \
	  if grep -q '^warning:' .typst.log; then cat .typst.log; rm -f .typst.log; exit 1; fi; \
	done; rm -f .typst.log .check.pdf

clean:
	rm -f $(PDFS)

.PHONY: all check clean
