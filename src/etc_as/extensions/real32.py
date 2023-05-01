from etc_as.core import Extension
from etc_as.extensions import mode_register

real32 = Extension(16, "real32", "32 Bit Address Space")

@real32.set_init
def real32_init(context):
    context.ip_mask = 0xFFFF_FFFF
    mode_register.enable(context)
