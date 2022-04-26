from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
.half 'H' 'e' 'l' 'l' 'o' ',' ' ' 'W' 'o' 'r' 'l' 'd' '!'
.align 2
.ascii "Hello, World!"
.align 4
.asciiz "Hello, World!"
.align 8, 0xFF
.utf8 "Äuglein 👀"
.align 16
.p2align 16 ,, 16
""")

print(res.to_bytes().hex(' ', -2))
