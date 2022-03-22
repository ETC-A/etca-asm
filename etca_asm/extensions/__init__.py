import pkgutil


def import_all_extensions():
    import etca_asm.base_isa
    for args in pkgutil.iter_modules(__path__):
        __import__(f'{__name__}.{args.name}')
