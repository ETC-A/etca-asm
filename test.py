from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
.set test '\\n'
.dword test
""")

print(res.to_bytes().hex(' ', 2))
