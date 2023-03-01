ASM   ?= etc-as.py
MODES ?= bin ann
DIFF   = diff -u

FAILED = ( mv $*.out $*.fail && false )

SOURCES = $(wildcard *.s)
TESTS = $(wildcard *.bin) \
		$(wildcard *.ann) \
		$(wildcard *.tc)  \
		$(wildcard *.tc64)
OUTS += $(foreach TEST, $(TESTS), $(TEST).out)

.bin_FORMAT  = -mformat=binary
.ann_FORMAT  = -mformat=annotated
.tc_FORMAT   = -mformat=tc
.tc64_FORMAT = -mformat=tc-64
_FORMAT      = -mformat=

%.test: % %.out
	$(DIFF) $* $*.out || $(FAILED)

%.accept:
	[ ! -f $*.fail ] || mv $*.fail $*


test: $(TESTS:=.test)
accept-all: $(TESTS:=.accept)

generate: $(foreach MODE, $(MODES), $(SOURCES:.s=.$(MODE).out))
	for f in *.out; do               \
		mv -- "$$f" "$${f%.out}"; \
	done

.SECONDEXPANSION:

%.out: $$(basename $$*).s
	head -n 1 $< | cut -c 2- | xargs $(ASM) $< $($(suffix $*)_FORMAT) -o $@
