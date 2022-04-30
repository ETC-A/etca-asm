#!/usr/bin/env python3
from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler(verbosity=10)

res = ass.n_pass("""
.org 0x400
.half 'H' 'e' 'l' 'l' 'o' ',' ' ' 'W' 'o' 'r' 'l' 'd' '!'
.org 0x420
.align 2
.ascii "Hello, World!"
.align 4
.asciiz "Hello, World!"
.align 8, 0xFF
.utf8 "Äuglein 👀"
.align 16
.word $
.half 0xFF
.word $
.align 4
.half 0xAB
.half (0xCD)
.half 0x10 + 0x13
.half 0x2 * 0x3
.half 0x10 / 0x7
.half 0xA % 0x3
.p2align 8 ,, 16
""")

print(res.to_bytes().hex(' ', -2))
