from etca_asm.core import Extension

qword = Extension(4, "qword_operations", "Quad Word Operations")


@qword.set_init
def qword_ext_init(context):
    context.__dict__.setdefault('register_sizes', {})['q'] = 3


@qword.register_syntax("size_postfix", r"/(?!<\s)q/")
@qword.register_syntax("size_postfix", r"", strict=False)
def qword_size_postfix_q(context, q=None):
    return 'q' if q else None


@qword.register_syntax("size_infix", r"/(?!<\s)q(?!\s)/")
@qword.register_syntax("size_infix", r"", strict=False)
def qword_size_infix_d(context, q=None):
    return 'q' if q else None


@qword.register_syntax("size_prefix", r"/q(?!\s)/")
@qword.register_syntax("size_prefix", r"", strict=False)
def qword_size_prefix_q(context, q=None):
    return 'q' if q else None
