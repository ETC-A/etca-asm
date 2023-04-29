from etca_asm.core import Extension
from etca_asm.base_isa import NAMED_CRS

dword_ptrs = Extension(16, "dword_pointers", "32 Bit Address Space")

@dword_ptrs.set_init
def dword_ptrs_init():
    NAMED_CRS['mode'] = 17
