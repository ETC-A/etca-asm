from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
mov r0, -32768
mov r0, -31000
mov r0, -3100
mov r0, -310
mov r0, -31
mov r0, -16
mov r0, 0
mov r0, 16
mov r0, 17
mov r0, 31
mov r0, 310
mov r0, 3100
mov r0, 31000
mov r0, 65535
""")

print(res.to_bytes().hex(' ', 2))
