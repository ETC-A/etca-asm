# etca-asm

A basic implementation of an assembler for [ETCa](https://github.com/ETC-A/etca-spec). 
This is not supposed to be permanent solution and therefore this is not well designed everywhere. 
One of the goals is that it's at least reasoanbly easy to add extensions.

## Installation

This assembler was not aimed at being easy to use for those unfamiliar with a terminal. However, after some
requests from members of the Turing Complete discord server, we've added a simple installation system
that should walk you through getting everything required to use the assembler as easily as possible.

As always, _be careful_ when using `sudo`. You are giving programs administrator access to your machine.
You can see what commands will be run in the `Makefile` if you'd like to vet it for yourself.

### Dependency Installer

Run `sudo make deps` to get help installing the dependencies needed for `etc-as`. This command only works on
Debian-based Linux distributions, such as Ubuntu.

`python3.10` is needed. Then the packages `lark`, `frozendict` and `bitarray` need to be installed.

The dependency installation helper will install `python3.10` using the PPA (Personal Package Archive)
from the lovely people at deadsnakes. Then it will install the needed packages through python itself.

### One-Time Installation

From this repository, run `make build && sudo make install`.
This will install `etc-as` to your machine. Note that it will install whatever you cloned from github -
you'll need to `git pull` first if you want to install updates from our repository.

Afterwards, you should be able to run `etc-as` from any folder to see help text.

## Usage

The primary interface should be the frontend module `etc-as.py`, to be used similar the standard command `as`. For extended help, do `etc-as.py -h`.

The wrapper script `etc-as` can also be used instead. It tries to be helpful by doing a (naive) check for python versions that will work. After
`make install`, `etc-as` is the entrypoint that is expected to be used.
