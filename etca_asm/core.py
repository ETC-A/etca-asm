from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, TYPE_CHECKING, NamedTuple

import lark.load_grammar
from frozendict import frozendict
from lark import Lark, Transformer
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


available_extensions: dict[str, Extension] = {}

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
        assert self.name not in available_extensions
        available_extensions[self.strid] = self

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


core = Extension(None, "core", "Core Assembly", True)


def _resolve_label(context, name: tuple[int, str]) -> int | None:
    full_name = '.'.join((*context.last_labels[:name[0]], name[1]))
    if full_name in context.labels:
        return context.labels[full_name]
    else:
        context.missing_labels.add(full_name)
        return None


@core.set_init
def core_init(context):
    context.enabled_extensions = [e for e in available_extensions.values() if e.default_on]
    context.modes = set()
    context.ip = 0x8000
    context.labels = {}
    context.last_labels = ['']
    context.missing_labels = set()
    context.changed_labels = set()
    context.resolve_label = partial(_resolve_label, context)
    for e in available_extensions.values():
        if e.init is not None and e is not core:
            e.init(context)
    context.reload_extensions()


@core.inst('NAME ":"')
def global_label(context, name: str):
    context.last_labels = [str(name)]
    if context.labels.get(name, None) != context.ip:
        context.changed_labels.add(name)
    context.labels[name] = context.ip
    return b''


@core.inst(r'/\.+/ NAME ":"')
def local_label(context, dots: str, name: str):
    dot_count = len(dots)
    while len(context.last_labels) < dot_count:
        context.last_labels.append('')
    context.last_labels[dot_count:] = [name]
    full_name = '.'.join((*context.last_labels, name))
    if context.labels.get(full_name, None) != context.ip:
        context.changed_labels.add(full_name)
    context.labels[full_name] = context.ip
    return b''


@core.register_syntax('label', 'NAME')
def global_label_reference(context, name: str):
    return 0, str(name)


@core.register_syntax('label', r'/\.+/ NAME')
def local_label_reference(context, dots, name: str):
    return len(dots), str(name)


core.register_syntax('immediate', '/[+-]?[0-9]+(_[0-9]+)*/', lambda _, x: int(str(x), 10))
core.register_syntax('immediate', '/[+-]?0[bB]_?[01]+(_[01]+)*/', lambda _, x: int(x[2:].removeprefix('_'), 2))
core.register_syntax('immediate', '/[+-]?0[oO]_?[0-7]+(_[0-7]+)*/', lambda _, x: int(x[2:].removeprefix('_'), 8))
core.register_syntax('immediate', '/[+-]?0x_?[0-9a-f]+(_[0-9a-f]+)*/i', lambda _, x: int(x[2:].removeprefix('_'), 16))


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
        ext = available_extensions[ext]
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

    def __init__(self):
        self.context = Context()
        self.context.output = []
        self.context.reload_extensions = self.reload_extensions
        self.context.macro = self.macro
        core.init(self.context)

    def reload_extensions(self):
        grammar_builder = GrammarBuilder()
        grammar_builder.load_grammar(open(Path(__file__).with_name("instruction.lark")).read(), "instruction.lark")
        existing_syntax_elements = {"instruction"}
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
                    grammar_builder.load_grammar(grammar, alias)

        grammar = grammar_builder.build()
        # Maybe lexer=dynamic_complete is worth it, although it might mean a massive reduction in performance
        self.current_parser = Lark(grammar, parser='earley', lexer='dynamic', ambiguity="explicit",
                                   start="instruction", propagate_positions=True)

    def handle_instruction(self, line):
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
            self.handle_instruction(line)

    def n_pass(self, full_text) -> AssemblyResult:
        self.single_pass(full_text)
        while self.context.missing_labels or self.context.changed_labels:
            old = self.context.missing_labels, self.context.changed_labels
            old_labels = self.context.labels.copy()
            core.init(self.context)
            self.context.labels = old_labels
            self.context.output = []
            self.single_pass(full_text)
            if old == (self.context.missing_labels, self.context.changed_labels):
                raise ValueError(f"Stuck without further progress, still missing labels {self.context.missing_labels}")
        return AssemblyResult(self.context.output)
