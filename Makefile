.PHONY: test tags clean

NVIM ?= nvim

test:
	@./scripts/test.sh

# Maintainer: regenerate doc/tags after editing doc/csa.txt
tags:
	@$(NVIM) --headless -u NONE -c "set rtp+=." -c "helptags doc" -c "quit"
	@echo "doc/tags updated"

clean:
	@rm -rf .testdata
