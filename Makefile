# Makefile for simple-as-possible etc-as installation.

BUILD_DIR   := .build
BUILD_LOCAL := $(abspath $(BUILD_DIR)/local)
LOCAL_LIB   := $(BUILD_LOCAL)/lib
LOCAL_BIN   := $(BUILD_LOCAL)/bin

INSTALL_PREFIX := /usr
INSTALL_BIN    ?= $(INSTALL_PREFIX)/bin
INSTALL_LIB    ?= $(INSTALL_PREFIX)/lib/etc-as

ETC_AS_BIN := $(BUILD_DIR)$(INSTALL_BIN)
ETC_AS_LIB := $(BUILD_DIR)$(INSTALL_LIB)

ETC_AS := etc-as

ETC_AS_VERSION ?= $(shell cat etca_asm/version)
ETC_AS_RELEASE ?= v$(ETC_AS_VERSION)-$(shell git rev-parse --short HEAD)

.PHONY: all build clean deps test install uninstall

all: build

clean:
	rm -rf $(ETC_AS_BIN) $(ETC_AS_LIB)

test:
	cd tests/golden && $(MAKE) test

# "Building"
# Prepare the files for copy by moving only the ones that we need to
# a local .build directory.

etc_as_files :=                     \
	etc-as.py                       \
	etca_asm/__init__.py            \
	etca_asm/base_isa.py            \
	etca_asm/common_macros.py       \
	etca_asm/core.py                \
	etca_asm/instruction.lark       \
	etca_asm/extensions/__init__.py \
	etca_asm/extensions/byte_operations.py \
	etca_asm/extensions/dword_operations.py \
	etca_asm/extensions/qword_operations.py \
	etca_asm/extensions/stack_and_functions.py

$(ETC_AS_LIB)/%.py: %.py
	@mkdir -p $(dir $@)
	install $< $@

$(ETC_AS_LIB)/%.lark: %.lark
	@mkdir -p $(dir $@)
	install $< $@

# Installing
# Put everything in `/usr/` space

install_bins := $(ETC_AS)
install_libs := $(etc_as_files) version

build_bins := $(install_bins)
build_libs := $(install_libs)

$(ETC_AS_BIN)/$(ETC_AS): $(ETC_AS)
	@mkdir -p $(dir $@)
	install $< $@

$(ETC_AS_LIB)/version:
	@mkdir -p $(dir $@)
	echo $(ETC_AS_RELEASE) > $@

build: $(patsubst %, $(ETC_AS_BIN)/%, $(install_bins)) \
       $(patsubst %, $(ETC_AS_LIB)/%, $(install_libs))

all_bin_sources := $(shell find $(ETC_AS_BIN) -type f | sed 's|^$(ETC_AS_BIN)/||')
all_lib_sources := $(shell find $(ETC_AS_LIB) -type f | sed 's|^$(ETC_AS_LIB)/||')

install: $(patsubst %, $(DESTDIR)$(INSTALL_BIN)/%, $(all_bin_sources)) \
         $(patsubst %, $(DESTDIR)$(INSTALL_LIB)/%, $(all_lib_sources))

$(DESTDIR)$(INSTALL_BIN)/%: $(ETC_AS_BIN)/%
	@mkdir -p $(dir $@)
	install $< $@

$(DESTDIR)$(INSTALL_LIB)/%: $(ETC_AS_LIB)/%
	@mkdir -p $(dir $@)
	install $< $@

uninstall:
	rm -rf $(DESTDIR)$(INSTALL_BIN)/$(ETC_AS)
	rm -rf $(DESTDIR)$(INSTALL_LIB)

# Install dependencies if they aren't present

APT_VERSION := $(shell apt-get --version)
PYTHON_3_10 ?= python3.10
PYTHON_3_10_VERSION := $(shell $(PYTHON_3_10) --version)

ifeq (,$(APT_VERSION))
deps:
	$(error Sorry, the dependency install walkthrough only works on apt-based systems. Check the README and do a manual install.)
else
deps: python310 python-packages
endif

python310:
ifeq (,$(PYTHON_3_10_VERSION))
	echo "This install walkthrough is going to use sudo several times, which requires a password."
	echo "Please only use this tool if you trust us, and feel free to ask what each step is doing."
	sudo apt install software-properties-common -y
	sudo add-apt-repository ppa:deadsnakes/ppa
	sudo apt install $(PYTHON_3_10)
endif

python-packages: python310
	$(PYTHON_3_10) -m pip install lark frozendict bitarray
