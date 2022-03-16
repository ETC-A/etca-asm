from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, TYPE_CHECKING

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
            while (sid := f'{f.__name__}_{i}') in self.syntax_elements_by_id:
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


@core.set_init
def core_init(context):
    context.enabled_extensions = [e for e in available_extensions.values() if e.default_on]
    context.modes = set()
    context.start_position = 0x8000
    for e in available_extensions.values():
        if e.init is not None and e is not core:
            e.init(context)
    context.reload_extensions()


@core.inst('NAME ":"')
def global_label(context, name: str):
    raise NotImplementedError


@core.inst(r'/\.+/ NAME ":"')
def local_label(context, dots: str, name: str):
    raise NotImplementedError


class _CompileInstruction(Transformer):
    def __init__(self, context):
        super().__init__()
        self.context = context

    def __default__(self, data, children, meta):
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


class Assembler:
    current_parser: Lark

    def __init__(self):
        self.context = Context()
        self.context.reload_extensions = self.reload_extensions
        core.init(self.context)

    def reload_extensions(self):
        grammar_builder = GrammarBuilder()
        grammar_builder.load_grammar(open(Path(__file__).with_name("instruction.lark")).read(), "instruction.lark")
        for extension in self.context.enabled_extensions:
            extension: Extension
            for required_modes, syntax in extension.syntax_elements.items():
                if any((m in self.context.modes) != expected for m, expected in required_modes.items()):
                    continue
                for s in syntax:
                    alias = f"{s.extension.strid}__{s.strid}"
                    grammar = f"%extend {s.category}: ({s.grammar}) -> {alias}"
                    grammar_builder.load_grammar(grammar, alias)

        grammar = grammar_builder.build()
        # Maybe lexer=dynamic_complete is worth it, although it might mean a massive reduction in performance
        self.current_parser = Lark(grammar, parser='earley', lexer='dynamic', ambiguity="explicit", start="instruction")

    def handle_instruction(self, line):
        tree = self.current_parser.parse(line)
        if tree.data == "no_instruction":
            return
        options = CollapseAmbiguities().transform(tree)
        if len(options) > 1:
            for option in options:
                print(option)
            raise NotImplementedError("Ambiguity is not implemented")
        inst, = options
        result = _CompileInstruction(self.context).transform(inst)
        print(result)

    def single_pass(self, full_text: str):
        for line in full_text.splitlines(False):
            self.handle_instruction(line)
