# etca-asm

A basic implementation of an assembler for [ETCa](https://github.com/MegaIng/ETC.a). 
This is not supposed to be permanent solution and therefore this is not well designed everywhere. 
One of the goals is that it's at least reasoanbly easy to add extensions.

## Installation

`python3.10` or higher is needed. Then the packages `lark`, `frozendict` and `bitarray` need to be installed.

## Usage
The primary interface should be the frontend module `etc-as.py`, to be used similar the standard command `as`. For extended help, do `etc-as.py -h`.
