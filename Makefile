.PHONY: test install check

check:
	shellcheck klue

test:
	bash_unit tests/test_klue.sh

install:
	install -m 755 klue /usr/local/bin/klue
