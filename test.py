from etca_asm.core import Assembler

import etca_asm.core
import etca_asm.base_isa
import etca_asm.common_macros
import etca_asm.extensions

etca_asm.extensions.import_all_extensions()

ass = Assembler()

res = ass.n_pass("""
.extension byte_operations,functions
    mov     ax0, 5
    call    fib
    hlt
fib:
    mov     vh0, ah0
    cmp     ax0, 1
    retbe
    push    lnx
    push    sx0
    sub     ah0, 1
    push    ax0
    call    fib
    mov     sh0, vh0
    pop     ax0
    sub     ah0, 1
    call    fib
    add     vh0, sh0
    pop     sx0
    pop     lnx
    ret


""")

print(res.to_bytes().hex(' ', 2))
