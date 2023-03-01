#!/usr/bin/env python3.10
import argparse
import fnmatch
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path
from pprint import pprint
from dataclasses import dataclass


def parse_args(args):
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--command", action="store", default="python3.10 etc-as.py",
                        help="The assembler to test")
    parser.add_argument("-i", "--include", action="append",
                        help="A glob-like pattern of which golden tests to include")
    parser.add_argument("-e", "--exclude", action="append",
                        help="A glob-like pattern of which golden tests to exclude")
    parser.add_argument("--folder", action="store", type=Path, default=Path(__file__).parent,
                        help="The folder in which the golden tests are.")
    parser.add_argument("--gen", action="append",
                        help="Generate the files for these formats. Skips all comparisons", choices=list(output_modes))
    return parser.parse_args(args)


@dataclass
class GoldenTestCase:
    name: str
    assembly_file: Path
    compare_files: dict[str, Path]


output_modes = {
    'bin': "binary",
    'ann': "annotated",
    'tc': "tc",
    'tc64': "tc-64",
}


def collect_test_cases(ns):
    for assembly_file in ns.folder.glob("*.s"):
        name = assembly_file.stem
        if ns.include:
            if not any(fnmatch.fnmatch(name, p) for p in ns.include):
                continue
        if ns.exclude:
            if any(fnmatch.fnmatch(name, p) for p in ns.exclude):
                continue
        if ns.gen:
            yield GoldenTestCase(name, assembly_file, {})
            continue
        compare_files = {}
        for suffix, mode in output_modes.items():
            path = assembly_file.with_suffix('.' + suffix)
            if path.is_file():
                compare_files[mode] = path
        if not compare_files:
            print(f"Assembly file with no output files to check against, skipping: {assembly_file.name}")
            continue
        yield GoldenTestCase(name, assembly_file, compare_files)


def main(args):
    ns = parse_args(args)
    command_base = shlex.split(ns.command)
    with tempfile.TemporaryDirectory() as tmp_dir:
        p = Path(tmp_dir)
        for test_case in collect_test_cases(ns):
            first_line = test_case.assembly_file.read_text().partition("\n")[0].strip()
            if first_line[0] != ";":
                extra_arguments = []
            else:
                extra_arguments = shlex.split(first_line.partition(";")[2].strip())
            if ns.gen:
                for suffix in ns.gen:
                    path = test_case.assembly_file.with_suffix('.' + suffix)
                    command = [
                        *command_base,
                        "-o", path,
                        f"-mformat={output_modes[suffix]}",
                        *extra_arguments,
                        test_case.assembly_file
                    ]
                    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if process.returncode != 0:
                        print(f"Assembler call for {test_case.name} failed with return code {process.returncode}")
                        print(process.stderr.decode())
                        continue
            else:
                for mode, path in test_case.compare_files.items():
                    tmp = p / path.name
                    command = [
                        *command_base,
                        "-o", tmp,
                        f"-mformat={mode}",
                        *extra_arguments,
                        test_case.assembly_file
                    ]
                    process = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if process.returncode != 0:
                        print(f"Assembler call for {test_case.name} failed with return code {process.returncode}")
                        print(process.stderr.decode())
                        continue
                    expected = path.read_bytes()
                    got = tmp.read_bytes()
                    if expected != got:
                        print(f"Output {mode} for {test_case.name} did not match expected, creating .fail file")
                        shutil.move(tmp, path.with_suffix(path.suffix + ".fail"))


if sys.version_info[0:2] < (3, 10):
    print('Python 3.10 or newer is required to run this')
    exit(code=1)


if __name__ == '__main__':
    import sys

    main(sys.argv[1:])
