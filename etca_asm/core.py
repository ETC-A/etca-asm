from __future__ import annotations
from cgitb import enable

import copy
import logging
from collections import defaultdict
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path
from pprint import pformat
from types import SimpleNamespace
from typing import Callable, TYPE_CHECKING, NamedTuple

import lark.load_grammar
from frozendict import frozendict
from lark import Lark, Transformer, GrammarError
from lark.load_grammar import GrammarBuilder
from lark.visitors import CollapseAmbiguities


class Context(SimpleNamespace):
    pass


@dataclass
class SyntaxElement:
    extension: Extension
    category: str
    grammar: str
    func: Callable
    strid: str
    required_markers: frozendict[str, bool]


potential_extensions: dict[str, Extension] = {}

core: Extension


@dataclass
class Extension:
    cpuid: int | None
    strid: str
    name: str
    default_on: bool = False
    init: Callable = None

    syntax_elements: dict[frozendict[str, bool], list[SyntaxElement]] = field(default_factory=lambda: defaultdict(list))
    syntax_elements_by_id: dict[str, SyntaxElement] = field(default_factory=dict)

    def __post_init__(self):
        assert self.name not in potential_extensions
        potential_extensions[self.strid] = self

    def register_syntax(self, category: str, grammar, func=None, /, **kwargs: bool):
        def dec(f):
            markers = frozendict(kwargs)
            i = 0
            f_name = f.__name__ if f.__name__.isidentifier() else "unknown"
            while (sid := f'{f_name}_{i}') in self.syntax_elements_by_id:
                i += 1
            self.syntax_elements[markers].append(se := SyntaxElement(self, category, grammar, f, sid, markers))
            self.syntax_elements_by_id[sid] = se
            return f

        if func is None:
            return dec
        else:
            return dec(func)

    def inst(self, grammar, /, **kwargs: bool):
        return self.register_syntax("instruction", grammar, **kwargs)

    def reg(self, grammar, /, **kwargs: bool):
        return self.register_syntax("register", grammar, **kwargs)

    def set_init(self, func_or_none=None):
        if func_or_none is not None:
            self.init = func_or_none
            return func_or_none
        else:
            return self.set_init

    def __repr__(self):
        return f"<Extension: {self.strid} {self.name!r}>"


core = Extension(None, "core", "Core Assembly", True)


def _resolve_symbol(context, name: tuple[int, str]) -> int | None:
    full_name = '.'.join((*context.symbol_path[:name[0]], name[1]))
    if full_name in context.symbols:
        return context.symbols[full_name]
    else:
        context.missing_symbols.add(full_name)
        return None


@core.set_init
def core_init(context):
    context.enabled_extensions = [e for a in context.available_extensions
                                  if (e := potential_extensions[a]).default_on]
    context.modes = set()
    context.ip = 0x8000
    context.symbols = {}
    context.symbol_path = ['']
    context.missing_symbols = set()
    context.changed_symbols = set()
    context.resolve_symbol = partial(_resolve_symbol, context)
    for e in potential_extensions.values():
        if e.init is not None and e is not core:
            e.init(context)
    context.reload_extensions()

def oneof(*names):
    names=sorted(names, key=len, reverse=True)
    return f"({'|'.join(names)})"

_WORD_SIZES = {
    '.half': 1,
    '.word': 2,
    '.dword': 4,
}


@core.inst(fr'/{oneof(*_WORD_SIZES)}/ immediate')
def put_word(context, size, value):
    return value.to_bytes(_WORD_SIZES[size], "little")


@core.inst(r'".set" symbol immediate')
def set_symbol(context, symbol, value):
    dot_count, name = symbol
    while len(context.symbol_path) < dot_count:
        context.symbol_path.append('')
    context.symbol_path[dot_count:] = [name]
    full_name = '.'.join((*context.symbol_path[:dot_count], name))
    if context.symbols.get(full_name, None) != value:
        context.changed_symbols.add(full_name)
    context.symbols[full_name] = value
    return b''


@core.inst('NAME ":"')
def global_label(context, name: str):
    set_symbol(context, (0, name), context.ip)
    return b''


@core.inst(r'/\.+/ NAME ":"')
def local_label(context, dots: str, name: str):
    set_symbol(context, (len(dots), name), context.ip)
    return b''


@core.register_syntax('symbol', 'NAME')
def global_symbol_reference(context, name: str):
    return 0, str(name)


@core.register_syntax('symbol', r'/\.+/ NAME')
def local_symbol_reference(context, dots, name: str):
    return len(dots), str(name)


@core.inst(r'".extension" /\w+/ ( "," /\w+/)*')
def enable_extension(context, *names: str):
    for name in names:
        if name not in context.available_extensions:
            raise ValueError(f"Unknown extension {name!r}, expected one of {list(context.available_extensions)}")
        ext = potential_extensions[name]
        if ext not in context.enabled_extensions:
            context.enabled_extensions.append(ext)
    context.reload_extensions()


core.register_syntax('immediate', '/[+-]?[0-9]+(_[0-9]+)*/', lambda _, x: int(str(x), 10))
core.register_syntax('immediate', '/[+-]?0[bB]_?[01]+(_[01]+)*/', lambda _, x: int(x[2:].removeprefix('_'), 2))
core.register_syntax('immediate', '/[+-]?0[oO]_?[0-7]+(_[0-7]+)*/', lambda _, x: int(x[2:].removeprefix('_'), 8))
core.register_syntax('immediate', '/[+-]?0x_?[0-9a-f]+(_[0-9a-f]+)*/i', lambda _, x: int(x[2:].removeprefix('_'), 16))


@core.register_syntax('immediate', 'symbol')
def immediate_symbol(context, symbol):
    value = context.resolve_symbol(symbol)
    if value is None:
        # This symbol is not defined right now. To simplify instruction creators, make it 0 in this pass
        return 0
    else:
        return value


class _CompileInstruction(Transformer):
    def __init__(self, context, line):
        super().__init__()
        self.context = context
        self.line = line

    def __default__(self, data, children, meta):
        if data.endswith('_raw'):
            return self.line[meta.start_pos:meta.end_pos]
        assert '__' in data, (data, children)
        ext, _, sid = data.partition('__')
        ext = potential_extensions[ext]
        se = ext.syntax_elements_by_id[sid]
        return se.func(self.context, *children)


class _RejectionError(BaseException):
    pass


def reject(cond=True, *args):
    if cond:
        raise _RejectionError(args)


class InstructionOutput(NamedTuple):
    start_ip: int
    binary: bytes
    raw_line: str


@dataclass()
class AssemblyResult:
    output: list[InstructionOutput]

    def to_bytes(self, starting_at=0x8000) -> bytes:
        out = bytearray()
        ip = starting_at
        for i in self.output:
            if i.start_ip > ip:
                out += b"\x00" * (i.start_ip - ip)
                ip += (i.start_ip - ip)
            elif i.start_ip < ip:
                raise ValueError("Instruction placed before earlier instruction", i, ip)
            out += i.binary
            ip += len(i.binary)
        return bytes(out)


class Assembler:
    current_parser: Lark

    def __init__(self, default_modes=None, available_extensions=None, logger: logging.Logger = None):
        self.context = Context()
        # Maybe these should be different loggers ?
        self.logger = logger or logging.getLogger(__name__)
        self.setup_context(True, default_modes=default_modes, available_extensions=available_extensions)
        core.init(self.context)
        self.context.modes = default_modes or set()

    def setup_context(self, full_reset=False, **extras):
        self.context.logger = self.logger
        self.context.reload_extensions = self.reload_extensions
        self.context.macro = self.macro
        if full_reset:
            self.context.output = []
            self.context.available_extensions = extras.pop('available_extensions', None) or set(potential_extensions)
            self.context.modes = extras.pop('default_modes', None) or set()
        for k, v in extras.items():
            setattr(self.context, k, v)

    def set_default_size(self):
        strids = map(lambda e: e.strid, self.context.enabled_extensions)
        size = 'x'
        if 'qword_operations' in strids:
            size = 'q'
        elif 'dword_operations' in strids:
            size = 'd'
        self.context.default_size = size

    def reload_extensions(self):
        self.set_default_size()

        grammar_builder = GrammarBuilder()
        grammar_builder.load_grammar(open(Path(__file__).with_name("instruction.lark")).read(), "instruction.lark")
        existing_syntax_elements = {"instruction"}
        full_grammar = ""
        for extension in self.context.enabled_extensions:
            extension: Extension
            for required_modes, syntax in extension.syntax_elements.items():
                if any((m in self.context.modes) != expected for m, expected in required_modes.items()):
                    continue
                for s in syntax:
                    alias = f"{s.extension.strid}__{s.strid}"
                    if s.category in existing_syntax_elements:
                        grammar = f"%extend {s.category}: ({s.grammar}) -> {alias}"
                    else:
                        grammar = f"{s.category}: ({s.grammar}) -> {alias}"
                        grammar += f"\n{s.category}_raw: {s.category}"
                        existing_syntax_elements.add(s.category)
                    full_grammar += grammar + "\n"
                    grammar_builder.load_grammar(grammar, alias)

        self.logger.debug(full_grammar)
        try:
            grammar = grammar_builder.build()
        except GrammarError as e:
            raise e
        # Maybe lexer=dynamic_complete is worth it, although it might mean a massive reduction in performance
        self.current_parser = Lark(grammar, parser='earley', lexer='dynamic', ambiguity="explicit",
                                   start="instruction", propagate_positions=True)

    def handle_instruction(self, line):
        self.logger.debug(f"Enabled extensions: {self.context.enabled_extensions}")
        self.logger.debug(f"Active modes: {self.context.modes}")
        self.logger.debug(pformat(self.context))
        tree = self.current_parser.parse(line)
        if tree.data == "no_instruction":
            return
        options = CollapseAmbiguities().transform(tree)
        results = []
        rejections = []
        for option in options:
            try:
                result = _CompileInstruction(self.context, line).transform(option)
            except _RejectionError as e:
                rejections.append(e)
                continue
            else:
                results.append(result)
        if not results:
            raise NotImplementedError("Everyone rejected", line, rejections)
        if len(results) > 1:
            raise NotImplementedError("Prioritization is not implemented", results)
        result, = results
        if result is not None:
            self.context.output.append(InstructionOutput(self.context.ip, result, line))
            self.context.ip += len(result)

    def macro(self, instructions: str):
        old_output, old_ip = self.context.output, self.context.ip
        self.context.output = new_output = []
        try:
            for line in instructions.splitlines(False):
                self.handle_instruction(line)
        finally:
            self.context.output, self.context.ip = old_output, old_ip
        return b''.join(o.binary for o in new_output)

    def single_pass(self, full_text: str):
        for line in full_text.splitlines(False):
            self.logger.debug(f"Starting with line: {line!r}")
            self.handle_instruction(line)
            self.logger.debug(f"Done with line    : {line!r}")

    def n_pass(self, full_text) -> AssemblyResult:
        start_context = copy.deepcopy(self.context)
        self.single_pass(full_text)
        while self.context.missing_symbols or self.context.changed_symbols:
            old = self.context.missing_symbols, self.context.changed_symbols
            old_symbols = self.context.symbols.copy()
            self.context = copy.deepcopy(start_context)
            self.setup_context(False, symbols = old_symbols)
            self.reload_extensions()
            self.single_pass(full_text)
            if old == (self.context.missing_symbols, self.context.changed_symbols):
                raise ValueError(f"Stuck without further progress, still missing symbols {self.context.missing_symbols}")
        return AssemblyResult(self.context.output)


def resolve_register_size(context, *sizes: str | None):
    sizes = set(sizes)
    sizes.difference_update({None})
    if len(sizes) == 0:
        return context.default_size
    elif len(sizes) == 1:
        return next(iter(sizes))
    else:
        reject(True, f"Conflicting register sizes: {sizes}")
