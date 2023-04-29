from etc_as.core import Extension

dword_ptrs = Extension(16, "real32", "32 Bit Address Space")

@dword_ptrs.register_syntax("control_register", f'"mode"', prefix=False)
@dword_ptrs.register_syntax("control_register", f'"%mode"', prefix=True)
def named_cr(context):
    return 17
