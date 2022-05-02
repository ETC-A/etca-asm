#!/usr/bin/env python3

from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
mov rx0, 0
mov rx0, -1
mov rx0, 0x100
mov rx0, 0x8000
mov rx0, 0x8001
.extension dword_operations
mov rd0, -66000
mov rd0, 1000000000
mov rd0, 3000000000
mov rd0, -1000000000
.extension qword_operations
mov rq0, 5000000000
mov rq0, -5000000000
""")

print(res.to_bytes().hex(' ', -2))
