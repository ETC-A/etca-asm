from etc_as.core import Extension

dword_ptrs = Extension(16, "real32", "32 Bit Address Space")

@dword_ptrs.register_syntax("control_register", f'"mode"', prefix=False)
@dword_ptrs.register_syntax("control_register", f'"%mode"', prefix=True)
def named_cr(context):
    return 17

@dword_ptrs.set_init
def dword_ptrs_init(context):
    context.ip_mask = 0xFFFF_FFFF