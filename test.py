import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.byte_operations
import etca_asm.dword_operations
import etca_asm.qword_operations
from etca_asm.core import Assembler

ass = Assembler()

res = ass.n_pass("""
.syntax prefix
.extension byte_operations, dword_operations, qword_operations
movq %rq0, 8
""")

print(res.to_bytes().hex(' ', 2))
