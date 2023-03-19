from etc_as.core import Extension

byte = Extension(3, "byte_operations", "Byte Operations")


@byte.set_init
def byte_ext_init(context):
    context.__dict__.setdefault('register_sizes', {})['h'] = 0


@byte.register_syntax("size_postfix", r"/(?!<\s)h/")
@byte.register_syntax("size_postfix", r"", strict=False)
def byte_size_postfix_h(context, h=None):
    return 'h' if h else None


@byte.register_syntax("size_infix", r"/(?!<\s)h(?!\s)/")
@byte.register_syntax("size_infix", r"", strict=False)
def byte_size_infix_h(context, h=None):
    return 'h' if h else None


@byte.register_syntax("size_prefix", r"/h(?!\s)/")
@byte.register_syntax("size_prefix", r"", strict=False)
def byte_size_prefix_h(context, h=None):
    return 'h' if h else None
