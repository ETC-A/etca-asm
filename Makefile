# Makefile for simple-as-possible etc-as installation.

ETC_AS := etc-as

.PHONY: all deps test install uninstall python310 python310-pip

all: install

test:
	cd tests/golden && $(MAKE) test


install:
	$(PYTHON_3_10) -m pip install .

uninstall:
	$(PYTHON_3_10) -m pip uninstall .

# Install dependencies if they aren't present

APT_VERSION := $(shell apt-get --version)
PYTHON_3_10 ?= python3.10
PYTHON_3_10_VERSION := $(shell $(PYTHON_3_10) --version)
PIP_3_10_VERSION := $(shell $(PYTHON_3_10) -m pip --version)

ifeq (,$(APT_VERSION))
deps:
	$(error Sorry, the dependency install walkthrough only works on apt-based systems. Check the README and do a manual install.)
else
deps: python310 python310-pip
endif

python310:
ifeq (,$(PYTHON_3_10_VERSION))
	echo "This install walkthrough is going to use sudo several times, which requires a password."
	echo "Please only use this tool if you trust us, and feel free to ask what each step is doing."
	sudo apt install software-properties-common -y
	sudo add-apt-repository ppa:deadsnakes/ppa
	sudo apt install $(PYTHON_3_10)
endif

python310-pip:
ifeq (,$(PIP_3_10_VERSION))
	sudo apt install python3-pip
endif
