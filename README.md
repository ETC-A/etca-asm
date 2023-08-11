# NOTICE OF DEPRECATION

The project currently available here is a python assembler for the ETCa architecture. It only supports single-file projects, and suffers horrifying performance degradation on assembly files exceeding a few hundred lines.

This was always intended to be a temporary assembler until we were ready to invest effort into a more feature-rich assembler which is not necessarily as easy to hack on. That project has now begun, at [etca-binutils-gdb](https://github.com/ETC-A/etca-binutils-gdb). It does not support all of the extensions supported by this assembler but is quickly catching up; additionally it supports multi-file projects via intermediate ELF objects, as is the standard for nearly every platform today.

Installation instructions for that assembler can be found at [that project's wiki](https://github.com/ETC-A/etca-binutils-gdb/wiki/Installation). It is currently suitable for use producing ELF executables (for which we are not aware of any system that can consume them, yet), or a binary dump (which can be used with TC FileLoader components). For a listing that can be used with a TC Program Component, we plan to provide a wrapper script in this repository.

In the meantime, the python assembler here still functions as documented. Thanks for your patience!

# etc-as

A basic implementation of an assembler for [ETCa](https://github.com/ETC-A/etca-spec). 
This is not supposed to be permanent solution and therefore this is not well designed everywhere. 
One of the goals is that it's at least reasoanbly easy to add extensions.

All discussion related to ETCa happen on the Turing Complete discord: https://discord.gg/Wjdz8RJp7R. Ask there if you need help or have an improvement suggestion. You also can create an issue or even a PR on github.

## Installation

This assembler was not aimed at being easy to use for those unfamiliar with a terminal. However, after some
requests from members of the Turing Complete discord server, we've added a simple installation system
that should walk you through getting everything required to use the assembler as easily as possible.

As always, _be careful_ when using `sudo`. You are giving programs administrator access to your machine.
You can see what commands will be run in the `Makefile` if you'd like to vet it for yourself.

### Without cloning with existing python3.10

When you already have `python3.10` install on your system, you can run `python3.10 -m pip install git+https://github.com/ETC-A/etca-asm` to install the assembler

### Dependency Installer

Run `sudo make deps` to get help installing the dependencies needed for `etc-as`. This command only works on
Debian-based Linux distributions, such as Ubuntu.

`python3.10` and `pip` is needed. Python package dependencies will be downloaded via `pip` while installing.

The dependency installation helper will install `python3.10` using the PPA (Personal Package Archive)
from the lovely people at deadsnakes.

### One-Time Installation

From this repository, run `sudo make install`.
This will install `etc-as` to your machine. Note that it will install whatever you cloned from github -
you'll need to `git pull` first if you want to install updates from our repository.

Afterwards, you should be able to run `etc-as` from any folder to see help text.

## Usage

The primary interface should be the frontend module `etc-as`, to be used similar the standard command `as`. For extended help, do `etc-as -h`.

Alternatively `python3.10 -m etc_as` can be used for the exact same interface. 
