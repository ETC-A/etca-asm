from etc_as.core import Extension
from etc_as.extensions import mode_register

real64 = Extension(32, "real64", "64 Bit Address Space")

@real64.set_init
def real32_init(context):
    context.ip_mask = 0xFFFF_FFFF_FFFF_FFFF
    mode_register.enable(context)
