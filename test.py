import etca_asm.core
import etca_asm.base_isa
from etca_asm.core import Assembler

ass = Assembler()

res = ass.n_pass("""
.syntax prefix

""")

print(res.to_bytes().hex(' ', 2))
