from etca_asm.core import Extension

dword = Extension(14, "dword_operations", "Double Word Operations")


@dword.set_init
def dword_ext_init(context):
    context.__dict__.setdefault('register_sizes', {})['d'] = 2


@dword.register_syntax("size_postfix", r"/(?!<\s)d/")
@dword.register_syntax("size_postfix", r"", strict=False)
def dword_size_postfix_d(context, d=None):
    return 'd' if d else None


@dword.register_syntax("size_infix", r"/(?!<\s)d(?!\s)/")
@dword.register_syntax("size_infix", r"", strict=False)
def dword_size_infix_d(context, d=None):
    return 'd' if d else None


@dword.register_syntax("size_prefix", r"/d(?!\s)/")
@dword.register_syntax("size_prefix", r"", strict=False)
def dword_size_prefix_d(context, d=None):
    return 'd' if d else None
