import etca_asm.core
import etca_asm.base_isa
from etca_asm.core import Assembler


ass = Assembler()

ass.single_pass("""
.syntax prefix
.strict
addx %rx4, %rx7
jmp aa
""")