from __future__ import annotations

from etc_as import __version__
import etc_as.core as core
import etc_as.base_isa as base
import etc_as.common_macros
import etc_as.extensions as extensions
import logging
import sys


def assemble(in_file: str, out_file: str):
    global mformat, modes, verbosity
    extensions.import_all_extensions()
    if verbosity >= 5:
        logging.basicConfig(level='DEBUG')

    worker = core.Assembler(verbosity)
    worker.context.modes = modes
    worker.context.reload_extensions()

    with open(in_file, 'r', encoding="utf-8") as f:
        res = worker.n_pass(f.read())

    if mformat == 'binary':
        output_as_binary(res, out_file)
    elif mformat == 'annotated':
        output_as_annotated(res, out_file, (res.max_address_width + 7) // 8)
    elif mformat == 'tc':
        output_as_tc_8(res, out_file)
    elif mformat == 'tc-64':
        output_as_tc_64(res, out_file)
    else:
        raise ValueError(f'impossible mformat `{mformat}\'')


def output_as_binary(res, out_file):
    with open(out_file, 'bw') as f:
        f.write(res.to_bytes())


def output_as_tc_8(res, out_file):
    with open(out_file, 'w') as f:
        for instr in res.output_with_aligns():
            encoding = ' '.join(f'0x{b:02x}' for b in instr.binary)
            f.write(f"{encoding:10} # {instr.raw_line}\n")


def output_as_tc_64(res, out_file):
    with open(out_file, 'w') as f:
        bs = b''
        waiting = []

        def do_print():
            nonlocal bs, waiting
            for i in waiting:
                f.write(f"# {i.raw_line}\n")
            f.write(f"0x{int.from_bytes(bs[:8], 'little'):0{16}x}\n")
            bs = bs[8:]
            waiting = []

        for instr in res.output_with_aligns():
            waiting.append(instr)
            bs += instr.binary
            while len(bs) >= 8:
                do_print()
        while len(bs) > 0:
            do_print()


def output_as_annotated(res, out_file, address_width):
    address_mask = (1 << (address_width*8)) - 1
    with open(out_file, 'w') as f:
        for instr in res.output_with_aligns():
            encoding = ' '.join('{:02x}'.format(b) for b in instr.binary)
            f.write(f"0x{instr.start_ip & address_mask:0{address_width*2}x}: {encoding:30}# {instr.raw_line}\n")


args = sys.argv


def shift(n=1):
    global args
    args = [args[0]] + args[n + 1:]


usage_msg: str = f'''\
Usage: {args[0]} [option...] FILE\
'''

help_msg: str = usage_msg + f'''
Options:
  -V     --version        Print version number and exit
  -v                      Print progress information.
  -help  --help           Display this help message and exit.
  -o OBJFILE              Name the object file (default: a.out)
  -mformat=[binary|tc|tc-64|annotated] (default: annotated)
                          Control the assembled output format.
                          The tc and tc-64 formats are aimed at the game
                          "Turing Complete" and are deprecated-on-release.
                          They will be removed when the game no longer needs
                          their help.
  -mnaked-reg             Don't require `%' prefix requirement for registers
  -mstrict                Be strict about various things, including requiring
                          sizes attached to registers and instructions which
                          must agree.
  -mpedantic              Be extremely strict about everything.
                          Currently equivalent to -mstrict.\
'''


def print_version():
    print(__version__)
    exit()


def print_help():
    print(help_msg)
    exit()


def main():
    global modes, mformat, verbosity

    modes = set(['prefix'])
    mformat = 'annotated'
    asm_file: str = None
    obj_file: str = 'a.out'
    verbosity = 0
    unhandled = []
    while len(args) > 1:
        a = args[1]
        if a == '-V' or a == '--version':
            print_version()
        elif a == '-v':
            verbosity += 1; shift()
        elif a == '-help' or a == '--help':
            print_help()
        elif a == '-o':
            obj_file = args[2]; shift(2)
        elif a.startswith('-m'):
            a = a[2:]
            if a == 'strict' or a == 'pedantic':
                modes.add('strict'); shift()
            elif a == 'naked-reg':
                modes.remove('prefix'); shift()
            elif a.startswith('format='):
                a = a[7:]
                if a not in ['binary', 'tc', 'tc-64', 'annotated']: raise ValueError(f"unknown format: {a}")
                mformat = a;
                shift()
            else:
                unhandled += [a]; shift()
        elif a[0] != '-':
            asm_file = a; shift()
        else:
            unhandled += [a]; shift()

    if verbosity:
        print("Parsed command line arguments:")
        print(f"  modes:     {modes}")
        print(f"  format:    {mformat}")
        print(f"  in file:   {asm_file}")
        print(f"  objfile:   {obj_file}")
        print(f"  verbosity: {verbosity}")

    if len(unhandled) != 0:
        raise ValueError(f"unknown arguments: {unhandled}")

    assemble(asm_file, obj_file)
