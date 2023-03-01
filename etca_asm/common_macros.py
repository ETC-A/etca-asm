from etca_asm.core import Extension, reject, Context

common_macros = Extension(None, "common_macros", "Common Macros", True)


def sign_extend(value, bits):
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)

def split_into_bit_groups(imm):
    groups = []
    for i in range(60, -1, -5):
        groups.append((imm >> i) & 0x1F)
    return groups

@common_macros.inst('"mov" register_raw "," immediate')
def mov_large_immediate(context, reg, imm):
    reject_msg = f'Immediate is too large to fit in a register: {imm}'
    if -2**7 <= imm <= 2**8 - 1 and 'h':
        size = 'h'
    elif -2**15 <= imm <= 2**16 - 1:
        size = 'x'
    elif -2**31 <= imm <= 2**32 - 1:
        reject(not any(map(lambda x: x.strid == 'dword_operations', context.enabled_extensions)), reject_msg)
        size = 'd'
    elif -2**63 <= imm <= 2**64 - 1:
        reject(not any(map(lambda x: x.strid == 'qword_operations', context.enabled_extensions)), reject_msg)
        size = 'q'
    else:
        reject(reject_msg)
    
    bit_groups = split_into_bit_groups(imm)
    instructions = []

    # comparison is done with 16 instead of 0 so that 0-15 get mapped to movs instead of movz
    if imm < 16:
        # remove unneeded bit groups
        while len(bit_groups) > 1 and bit_groups[0] & 0x1F == 0x1F and bit_groups[1] & 0x10 != 0:
            bit_groups.pop(0)
        bit_groups[0] = sign_extend(bit_groups[0], 5)
        instructions.append(f'movs{size} {reg}, {bit_groups.pop(0)}')
    else:
        # remove unneeded bit groups
        while len(bit_groups) > 1 and bit_groups[0] == 0:
            bit_groups.pop(0)
        instructions.append(f'movz{size} {reg}, {bit_groups.pop(0)}')

    for group in bit_groups:
        instructions.append(f'slo{size} {reg}, {group}')

    return context.macro('\n'.join(instructions))
