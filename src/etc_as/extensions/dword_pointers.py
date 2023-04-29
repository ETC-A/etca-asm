from etc_as.core import Extension
from etc_as.base_isa import NAMED_CRS

dword_ptrs = Extension(16, "dword_pointers", "32 Bit Address Space")

@dword_ptrs.set_init
def dword_ptrs_init(context):
    NAMED_CRS['mode'] = 17
