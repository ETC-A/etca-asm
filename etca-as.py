#!/usr/bin/env python3
import subprocess
import sys
import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from string import hexdigits
from tempfile import TemporaryDirectory
from typing import TextIO


@dataclass
class SourceLine:
    lineno: int
    offset: int | None
    addr: int | None
    data: bytes | None
    text: str
    label_def: str | None

    @classmethod
    def parse(cls, s: str, word_count) -> 'SourceLine':
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
        if rest.strip() and rest.strip()[-1] == ':' and rest.strip()[:-1].isidentifier():
            label = rest.strip()[:-1]
        else:
            label = None
        return cls(lineno, address, address, data, rest.rstrip(), label)


@dataclass
class Listing:
    obj_name: str
    lines: list[SourceLine]

    @classmethod
    def parse(cls, obj_name: str, s: str, word_count) -> 'Listing':
        out = []
        last_index = -1
        for line in s.splitlines():
            if line:
                out.append(SourceLine.parse(line, word_count))
                assert out[-1].lineno > last_index
        return cls(obj_name, out)

    def out_tc(self, f: TextIO):
        for line in self.lines:
            encoding = ' '.join(f'0x{b:02x}' for b in (line.data or ()))
            f.write(f"{encoding:10} # {line.text}\n")

    def out_annotated(self, f: TextIO):
        address_width = 2
        address_mask = 0xFFFF
        for line in self.lines:
            if line.addr is not None:
                encoding = ' '.join('{:02x}'.format(b) for b in line.data or ())
                f.write(f"0x{line.addr & address_mask:0{address_width * 2}x}: {encoding:30}# {line.text}\n")
            else:
                f.write(f"{'':{address_width * 2 + 2}}  {'':30}# {line.text}\n")

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
        self = cls({},{})
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
            else:
                assert 'g' in sym.flags
                self.global_symbols[sym.name] = sym
        return self


@dataclass
class EtcaToolchain:
    program_prefix: str = "etca-elf-"
    program_location: Path | None = None
    march: str = None
    mcpuid: str = None
    temp_directory: Path = None
    _counter: int = 0

    def run(self, name: str, arguments: list[str], **kwargs) -> subprocess.CompletedProcess:
        full_name = f"{self.program_prefix}{name}"
        command_line = [
            (full_name if self.program_location is None else str(self.program_location / full_name)),
            *arguments
        ]
        return subprocess.run(command_line, **kwargs)

    def gas(self, input_file: Path, output_file: Path = None, listing=None, extras=()) -> Path | tuple[Path, bytes]:
        if output_file is None:
            output_file = self._get_out("as", ".o")
        arguments = []
        if self.march:
            arguments.append(f"-march={self.march}")
        if self.mcpuid:
            arguments.append(f"-mcpuid={self.mcpuid}")
        if listing:
            arguments.append(f"-{listing}")
        arguments.append(input_file)
        arguments.extend(["-o", output_file])
        arguments.extend(extras)
        res = self.run("as", arguments, stdout=(subprocess.PIPE if listing else None))
        res.check_returncode()
        if listing:
            return output_file, res.stdout
        else:
            return output_file

    def ld(self, input_files: list[Path], output_file: Path = None) -> Path:
        if output_file is None:
            output_file = self._get_out("ld", ".elf")
        arguments = []
        arguments.extend(input_files)
        arguments.extend(["-o", output_file])
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

    def objdump(self, input_file: Path, *args) -> bytes:
        arguments = [input_file, *args]
        res = self.run("objdump", arguments, stdout=subprocess.PIPE)
        res.check_returncode()
        return res.stdout

    @contextmanager
    def mktemp(self):
        temp_dir = TemporaryDirectory()
        self.temp_directory = Path(temp_dir.name)
        yield temp_dir.name
        self.temp_directory = None
        temp_dir.cleanup()

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
    passed_on = parser.add_argument_group(title="GAS arguments",
                                          description="These arguments are passed on to gas unchanged")
    passed_on.add_argument("-march", "--march", action="store")
    passed_on.add_argument("-mcpuid", "--mcpuid", action="store", )
    parser.add_argument("files", nargs="+", type=Path,
                        help="The input assembly files. They are assembled individually and then linked together.")
    return parser.parse_args(args)


def assemble(tool: EtcaToolchain, input_files: list[Path], output: Path, format: str) -> Path:
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
        for i, file in enumerate(input_files):
            o, l = tool.gas(file, listing="aln", extras=[
                "--listing-cont-lines", "0",
                "--listing-lhs-width", str(word_count)])
            object_files.append(o)
            listings.append(Listing.parse(o.name, l.decode(), word_count))
        elf_file = tool.ld(object_files)
        bin_file = tool.objcopy(elf_file, format="binary")
        symtab = SymbolTable.parse(tool.objdump(elf_file, '-t').decode(), [o.name for o in object_files])
        data = bin_file.read_bytes()
        assert len(listings) == 1
        last_addr = None
        for line in listings[0].lines:
            if line.data:
                line.data = data[line.offset:line.offset + len(line.data)]
            if line.label_def:
                if line.label_def in symtab.global_symbols:
                    line.addr = symtab.global_symbols[line.label_def].value
                elif (listings[0].obj_name, line.label_def) in symtab.local_symbols:
                    line.addr = symtab.local_symbols[(listings[0].obj_name, line.label_def)].value
                else:
                    raise ValueError(line)
            elif last_addr is not None and line.addr is not None:
                if last_addr[1] is None:
                    line.addr = last_addr[0]
                else:
                    line.addr = last_addr[0] + (line.offset-last_addr[1])
            if line.addr:
                last_addr = (line.addr, line.offset)
        with output.open("w") as f:
            if format == "tc":
                listings[0].out_tc(f)
            elif format == "tc-64":
                listings[0].out_tc64(f)
            elif format == "annotated":
                listings[0].out_annotated(f)
            else:
                raise ValueError(format)


def main(args, program_name=None):
    settings = parse_arguments(args, program_name)
    tool = EtcaToolchain()
    tool.march = settings.march
    tool.mcpuid = settings.mcpuid
    assemble(tool, settings.files, settings.output, settings.format)


if __name__ == '__main__':
    main(sys.argv[1:])
