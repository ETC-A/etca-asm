from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
.half 'H' 'e' 'l' 'l' 'o' ',' 'W' 'o' 'r' 'l' 'd' '!'
.word 0 0
.ascii "Hello, World!"
.word 0 0
.asciiz "Hello, World!"
""")

print(res.to_bytes().hex(' ', 2))
