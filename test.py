import etca_asm.core
import etca_asm.base_isa
from etca_asm.core import Assembler


ass = Assembler()

ass.n_pass("""
.syntax prefix

mov %r0, 1
slo %r0, 0x1F

""")