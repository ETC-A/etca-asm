import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
from etca_asm.core import Assembler

ass = Assembler()

res = ass.n_pass("""
.syntax prefix

mov %r0, 0x8000
""")

print(res.to_bytes().hex(' ', 2))
