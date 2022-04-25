from etca_asm.core import Extension, reject, Context

common_macros = Extension(None, "common_macros", "Common Macros", True)


def sign_extend(value, bits):
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


@common_macros.inst('/movx?/ register_raw "," immediate', strict=False)
@common_macros.inst('/movx/ register_raw "," immediate', strict=True)
def mov_large_immediate(context, _, reg, imm):
    reject(not ((-0x8000 <= imm < -0x10) or (0x10 <= imm <= 0xFFFF)))
    imm = imm & 0xFFFF
    if imm < 2 ** 9 or imm > 2 ** 16 - 2 ** 9:
        return context.macro(f"""
            movx {reg}, {sign_extend((imm & 0b11_1110_0000) >> 5, 5)}
            slox {reg}, {(imm & 0b00_0001_1111) >> 0}
        """)
    elif not bool(imm & 0x8000) and bool(imm & 0x4000):
        return context.macro(f"""
            movzx {reg}, {(imm & 0b0111_1100_0000_0000) >> 10}
            slox {reg}, {(imm & 0b0000_0011_1110_0000) >> 5}
            slox {reg}, {(imm & 0b0000_0000_0001_1111) >> 0}
        """)
    elif bool(imm & 0x8000) != bool(imm & 0x4000):
        return context.macro(f"""
            movx {reg}, {(imm & 0b1000_0000_0000_0000) >> 15}
            slox {reg}, {(imm & 0b0111_1100_0000_0000) >> 10}
            slox {reg}, {(imm & 0b0000_0011_1110_0000) >> 5}
            slox {reg}, {(imm & 0b0000_0000_0001_1111) >> 0}
        """)
    else:
        return context.macro(f"""
            movx {reg}, {sign_extend((imm & 0b0111_1100_0000_0000) >> 10, 5)}
            slox {reg}, {(imm & 0b0000_0011_1110_0000) >> 5}
            slox {reg}, {(imm & 0b0000_0000_0001_1111) >> 0}
        """)
