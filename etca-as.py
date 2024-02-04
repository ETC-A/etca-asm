#!/usr/bin/env python3
import subprocess
import sys
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from pprint import pprint
from string import hexdigits
from tempfile import TemporaryDirectory
from typing import TextIO, Iterable

# AbelianGrape:
#   When we encounter .data, .text, .bss, or .section <name> inside a macro
#   definition, we currently switch sections. We shouldn't do that.
#   Macro definitions are cleanly delimited by .macro and .endm and as far
#   as I know, they can't be nested.

@dataclass
class SourceLine:
    lineno: int
    offset: int | None
    addr: int | None
    data: bytes | None
    section: str
    text: str
    label_def: str | None

    @classmethod
    def parse(cls, s: str, word_count: int, prev_section: str) -> 'SourceLine':
        lineno, _, rest = s.lstrip().partition(' ')
        lineno = int(lineno)
        if rest[0] in hexdigits:  # We have an address and data in this line
            address, _, rest = rest.partition(' ')
            address = int(address, 16)
            data = bytes.fromhex(rest[:word_count * 9])  # 8 hex digits + 1 space per word
            rest = rest[word_count * 9 + 1:]  # plus one tab we strip out here
        else:
            address = data = None
            rest = rest[word_count * 9 + 4 + 1:]  # 4 byte address :-/
        section = prev_section
        label = None
        if rest.strip() and rest.strip()[-1] == ':' and rest.strip()[:-1].isidentifier():
            label = rest.strip()[:-1]
        elif rest.strip() and rest.strip("> ").startswith('.'):
            match rest.strip("> ").split():
                case ('.text' | '.data' | '.bss' as sec, *_):
                    section = sec
                case ('.section', name):
                    section = name
        return cls(lineno, address, address, data, section, rest.rstrip(), label)


def is_comment(text: str) -> bool:
    return not text.strip() or text.strip().startswith(';')


def next_or(iterable, default=None):
    try:
        return next(iterable)
    except StopIteration:
        return default


@dataclass
class Listing:
    source_name: str | None
    obj_name: str | None
    lines: list[SourceLine]

    @classmethod
    def parse(cls, source_name: str, obj_name: str, s: str, word_count) -> 'Listing':
        out = []
        last_index = -1
        sec = ".text"
        for line in s.splitlines():
            if line:
                out.append(SourceLine.parse(line, word_count, sec))
                sec = out[-1].section
                assert out[-1].lineno > last_index
        return cls(source_name, obj_name, out)

    def out_tc(self, f: TextIO):
        for line in self.lines:
            encoding = ' '.join(f'0x{b:02x}' for b in (line.data or ()))
            f.write(f"{encoding:10} # {line.text}\n")

    def out_annotated(self, f: TextIO, address_width: int = 16):
        width = address_width // 8
        address_mask = 2 ** (address_width) - 1
        for line in self.lines:
            if line.addr is not None:
                encoding = ' '.join('{:02x}'.format(b) for b in line.data or ())
                f.write(f"0x{line.addr & address_mask:0{width * 2}x}: {encoding:30}# {line.text}\n")
            else:
                f.write(f"{'':{width * 2 + 2}}  {'':30}# {line.text}\n")

    def out_tc64(self, f: TextIO):
        bs = b''
        waiting = []

        def do_print():
            nonlocal bs, waiting
            for i in waiting:
                f.write(f"# {i.text}\n")
            f.write(f"0x{int.from_bytes(bs[:8], 'little'):0{16}x}\n")
            bs = bs[8:]
            waiting = []

        for line in self.lines:
            waiting.append(line)
            if line.data:
                bs += line.data
            while len(bs) >= 8:
                do_print()
        while len(bs) > 0:
            do_print()

    @classmethod
    def combine(cls, listings: list['Listing'], keep_filter=lambda _: True, add_file_name=True):
        fragments = []
        for lis in listings:
            current = []
            if add_file_name and lis.source_name is not None:
                current.append(SourceLine(0, None, None, None, ".text", f"; {lis.source_name}", None))
            for line in lis.lines:
                if not line.data:
                    if keep_filter(line):
                        current.append(line)
                # Massive hack, but we need to be sure that we don't try to steal bytes from the
                # output for .bss lines containing .space. The right thing to do is handle
                # .space somewhere.
                elif line.section.startswith(".bss"):
                    line.data = None
                else:
                    current.append(line)
                    fragments.append((line.addr, current))
                    current = []
        fragments.sort(key=lambda t: t[0])
        offsets = {}
        res = []
        for frag in fragments:
            res.extend(frag[1])
            res[-1].offset = offsets.setdefault(res[-1].section, 0)
            offsets[res[-1].section] += len(res[-1].data)
        return cls(None, None, res)


formats = ["binary", "tc", "tc-64", "annotated"]


@dataclass
class Symbol:
    value: int
    flags: str
    section: str
    size: int
    name: str
    file_name: str = None

    @classmethod
    def parse(cls, line):
        # flags might have spaces inside of itself
        val, *flags, sec, size, name = line.split()
        flags = ''.join(flags).strip()
        return cls(int(val, 16), flags, sec, int(size, 16), name)


@dataclass
class SymbolTable:
    global_symbols: dict[str, Symbol]
    local_symbols: dict[(str, str), Symbol]

    @classmethod
    def parse(cls, text: str, file_names: list[str]):
        self = cls({}, {})
        _, _, data = text.partition("\nSYMBOL TABLE:\n")
        if not data:
            raise ValueError(text)
        current_file_name = None
        for line in data.splitlines():
            if not line.strip():
                continue
            sym = Symbol.parse(line)
            if sym.flags == "ldf" and sym.section == "*ABS*" and sym.value == 0:
                if sym.name in file_names:
                    current_file_name = sym.name
                else:
                    print("This is probably a file name, but we don't have such a file", sym)
            if 'l' in sym.flags:
                sym.file_name = current_file_name
                self.local_symbols[(sym.file_name, sym.name)] = sym
            elif 'g' in sym.flags:
                self.global_symbols[sym.name] = sym
            else:
                print("Unknown symbol kind", sym)
        return self


@dataclass
class EtcaToolchain:
    program_prefix: str = "etca-elf-"
    program_location: Path | None = None
    march: str = None
    mcpuid: str = None
    link_script: str = None
    temp_directory: Path = None
    _counter: int = 0

    def run(self, name: str, arguments: list[str], **kwargs) -> subprocess.CompletedProcess:
        full_name = f"{self.program_prefix}{name}"
        command_line = [
            (full_name if self.program_location is None else str(self.program_location / full_name)),
            *arguments
        ]
        return subprocess.run(command_line, **kwargs)

    def gas(self, input_file: Path, output_file: Path = None, listing=None, extras=()) -> Path | tuple[Path, Path]:
        if output_file is None:
            output_file = self._get_out("as", ".o")
        arguments = []
        if self.march:
            arguments.append(f"-march={self.march}")
        if self.mcpuid:
            arguments.append(f"-mcpuid={self.mcpuid}")
        if self.mcmodel:
            arguments.append(f"-mcmodel={self.mcmodel}")
        if self.mpw:
            arguments.append(f"-mpw={self.mpw}")
        if listing:
            if not isinstance(listing, tuple):
                listing = listing, self._get_out("as-listing", f".{listing}")
            arguments.append(f"-{listing[0]}={listing[1]}")
        arguments.append(input_file)
        arguments.extend(["-o", output_file])
        arguments.extend(extras)
        res = self.run("as", arguments)
        res.check_returncode()
        if listing:
            return output_file, listing[1]
        else:
            return output_file

    def ld(self, input_files: list[Path], output_file: Path = None) -> Path:
        if output_file is None:
            output_file = self._get_out("ld", ".elf")
        arguments = []
        arguments.extend(input_files)
        arguments.extend(["-o", output_file])
        if self.link_script:
            arguments.extend(["-T", self.link_script])
        res = self.run("ld", arguments)
        res.check_returncode()
        return output_file

    def objcopy(self, input_file: Path, output_file: Path = None, format="binary") -> Path:
        if output_file is None:
            output_file = self._get_out("objcopy", f".{format}")
        arguments = [input_file, output_file]
        arguments.extend(["-O", format])
        res = self.run("objcopy", arguments)
        res.check_returncode()
        return output_file

    def objcopy_extract(self, input_file: Path, sections: Iterable[str], format="binary") -> dict[str, Path]:
        output_files = {}
        arguments = [input_file]
        for section in sections:
            if section.startswith(".bss"):
                continue
            output_files[section] = self._get_out(f"objcopy-{section}", f".{format}")
            arguments.extend(["--dump-section", f"{section}={output_files[section]}"])
        res = self.run("objcopy", arguments)
        res.check_returncode()
        return output_files

    def objdump(self, input_file: Path, *args) -> bytes:
        arguments = [input_file, *args]
        res = self.run("objdump", arguments, stdout=subprocess.PIPE)
        res.check_returncode()
        return res.stdout

    @contextmanager
    def mktemp(self):
        if self.temp_directory is None:
            temp_dir = TemporaryDirectory()
            self.temp_directory = Path(temp_dir.name)
            yield temp_dir.name
            self.temp_directory = None
            temp_dir.cleanup()
        else:
            yield self.temp_directory

    def _get_out(self, name, suffix):
        if self.temp_directory is None:
            raise TypeError("No TempDir configured")
        self._counter += 1
        return self.temp_directory / f"{name}-output{self._counter - 1}{suffix}"


def parse_arguments(args, program_name=None):
    parser = argparse.ArgumentParser(program_name)
    parser.add_argument("--format", action="store", default="annotated", choices=formats,
                        help="Outputs in the corresponding format")
    parser.add_argument("-o", "--output", action="store", type=Path, default="a.out",
                        help="The file to write the result to. Defaults to 'a.out`")
    parser.add_argument("--temp", action="store", type=Path,
                        help="A temporary directory to put temporary files into."
                             " Will not be cleaned up automatically")

    passed_on_asm = parser.add_argument_group(title="GAS arguments",
                                          description="These arguments are passed onto gas unchanged")
    passed_on_asm.add_argument("-march", "--march", action="store")
    passed_on_asm.add_argument("-mcpuid", "--mcpuid", action="store", )
    passed_on_asm.add_argument("-mcmodel", "--mcmodel", action="store")
    passed_on_asm.add_argument("-mpw", "--mpw", action="store")


    passed_on_ld = parser.add_argument_group(title="LD arguments",
                                          description="These arguments are passed onto ld unchanged")
    passed_on_ld.add_argument("-T", "--script", action="store")

    parser.add_argument("files", nargs="+", type=Path,
                        help="The input assembly files. They are assembled individually and then linked together.")
    return parser.parse_args(args)


def assign_addresses(listing: Listing, symtab: SymbolTable):
    last_addr: dict[str, tuple[int, int | None] | None] = {}
    for line in listing.lines:
        if line.section is None:
            continue
        if line.label_def:
            if line.label_def in symtab.global_symbols:
                line.addr = symtab.global_symbols[line.label_def].value
            elif (listing.obj_name, line.label_def) in symtab.local_symbols:
                line.addr = symtab.local_symbols[(listing.obj_name, line.label_def)].value
            else:
                raise ValueError(line)
            last_addr[line.section] = (line.addr, line.offset)
        elif last_addr.get(line.section) and line.addr is not None:
            la = last_addr[line.section]
            if la[1] is None:
                line.addr = la[0]
            else:
                line.addr = la[0] + (line.offset - la[1])
        if line.offset is not None:
            last_addr[line.section] = (line.addr, line.offset)


def assemble(tool: EtcaToolchain, input_files: list[Path], output: Path, format: str) -> Path:
    """
    Assemble all `input_files` into a single file with the corresponding `format`.
    Uses the toolchain specified by `tool` and writes to `output`.

    if the `format` is `binary`, it shortcuts and directly assembles and links all files together to
    this one binary file

    Otherwise it assembles all files and generates listings, then reparses those listings into
    SourceLines and merges those together, then matches that up with the result of `ld` to
    generate a file annotated listing output.
    """
    with tool.mktemp():
        if format == "binary":
            object_files = []
            for i, file in enumerate(input_files):
                object_files.append(tool.gas(file))
            elf_file = tool.ld(object_files)
            return tool.objcopy(elf_file, output_file=output, format="binary")

        object_files = []
        listings = []
        word_count = 64

        # Assemble all files indvidually and collect the listings
        for i, file in enumerate(input_files):
            o, l = tool.gas(file, listing="alnm", extras=[
                "--listing-cont-lines", "0",
                "--listing-lhs-width", str(word_count),
                "-R"])
            object_files.append(o)
            listings.append(Listing.parse(file.name, o.name, l.read_text(), word_count))
            # print(*listings[-1].lines, sep="\n", end="\n\n")

        # Link together the .elf files
        elf_file = tool.ld(object_files)
        # Extract the final elf file into the various sections
        bin_files = tool.objcopy_extract(elf_file,
                                         set(l.section for listing in listings for l in listing.lines if l.section))
        data = {name: file.read_bytes() for name, file in bin_files.items()}
        # Get all symbols from the elf file
        symtab = SymbolTable.parse(tool.objdump(elf_file, '-t').decode(), [o.name for o in object_files])

        # Correct the addresses based on what the linker actually did
        for listing in listings:
            assign_addresses(listing, symtab)

        # Combine the listings according to what the linker did
        result = Listing.combine(listings)#, lambda line: line.label_def is not None)
        for line in result.lines:
            if line.data is not None:
                line.data = data[line.section][line.offset:line.offset + len(line.data)]
        # print(*result.lines, sep="\n", end="\n\n")

        # Output the resulting listing
        with output.open("w") as f:
            if format == "tc":
                result.out_tc(f)
            elif format == "tc-64":
                result.out_tc64(f)
            elif format == "annotated":
                result.out_annotated(f, parse_mpw(tool.mpw))
            else:
                raise ValueError(format)

def parse_mpw(value):
    try:
        return int(value)
    except ValueError:
        return {
            'x': 16,
            'xword': 16,
            'd': 32,
            'dword': 32,
            'q': 64,
            'qword': 64
        }.get(value, 16)

def main(args, program_name=None):
    settings = parse_arguments(args, program_name)
    tool = EtcaToolchain()
    tool.march = settings.march
    tool.mcpuid = settings.mcpuid
    tool.mcmodel = settings.mcmodel
    tool.mpw = settings.mpw
    tool.link_script = settings.script
    if settings.temp:
        tool.temp_directory = settings.temp
    assemble(tool, settings.files, settings.output, settings.format)


if __name__ == '__main__':
    main(sys.argv[1:])
