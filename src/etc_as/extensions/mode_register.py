# Maybe there's a better way to do this?
# This little extension just adds the %mode control
# register name. Address mode extensions should
# call mode_register.enable(context) in their init function.
from etc_as.core import Extension

mode_register = Extension(None, "modes", "Mode Register")

@mode_register.register_syntax("control_register", f'"mode"', prefix=False)
@mode_register.register_syntax("control_register", f'"%mode"', prefix=True)
def named_cr(context):
    return 17

def enable(context):
    if mode_register not in context.enabled_extensions:
        context.enabled_extensions.append(mode_register)
