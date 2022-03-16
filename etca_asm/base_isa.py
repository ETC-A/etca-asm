from bitarray import bitarray
from bitarray.util import int2ba

from etca_asm.core import Extension, reject

base = Extension(None, "base", "Base Instruction Set", True)

# @base.set_init
# def base_init(context):
#     context.modes

INSTRUCTIONS = {
    "add": 0x0,
    "sub": 0x1,
    "rsub": 0x2,
    "comp": 0x3,
    "cmp": 0x3,

    "or": 0x4,
    "xor": 0x5,
    "and": 0x6,
    "test": 0x7,

    "mov": 0x8,

    "load": 0xA, "ld": 0xA,
    "store": 0xB, "st": 0xB,

    "slo": 0xC,

    "port_read": 0xE,
    "port_write": 0xF,
}


def oneof(*names):
    return f"({'|'.join(names)})"


def build(*parts: tuple[int, int]):
    size = sum(w for v, w in parts)
    assert size % 8 == 0, "Instruction length must be multiple of a byte"
    data = bitarray(endian="big")
    i = 0
    for v, w in parts:
        data.extend(int2ba(v, w, endian="big"))
        i += w
    return data.tobytes()


# TODO: This should be something like "directive", not an "instruction"
@base.inst(f'".syntax" /(no)?prefix/')
def syntax_prefix(context, new_value):
    if new_value == "noprefix":
        context.modes.difference_update({'prefix'})
    else:
        context.modes.add('prefix')
    context.reload_extensions()


# TODO: This should be something like "directive", not an "instruction"
@base.inst(f'".strict"')
def strict(context):
    context.modes.add('strict')
    context.reload_extensions()


@base.reg(f"/%rx[0-7]/", strict=True, prefix=True)
@base.reg(f"/%rx?[0-7]/", strict=False, prefix=True)
@base.reg(f"/rx[0-7]/", strict=True, prefix=False)
@base.reg(f"/rx?[0-7]/", strict=False, prefix=False)
def base_registers(context, reg: str):
    return int(reg[-1])


@base.inst(f'/{oneof(*INSTRUCTIONS)}x/ register "," register', strict=True)
@base.inst(f'/{oneof(*INSTRUCTIONS)}x?/ register "," register', strict=False)
def base_computations_2reg(context, inst: str, a: int, b: int):
    reject(not isinstance(a, int) or not (0 <= a < 8), a)
    reject(not isinstance(b, int) or not (0 <= b < 8), b)
    inst = inst.removesuffix('x')
    op = INSTRUCTIONS[inst]
    if op >= 12:
        reject()
    return build((0b0001, 4), (op, 4), (a, 3), (b, 3), (0, 2))


@base.inst(f'/{oneof(*INSTRUCTIONS)}x/ register "," immediate', strict=True)
@base.inst(f'/{oneof(*INSTRUCTIONS)}x?/ register "," immediate', strict=False)
def base_computations_imm(context, inst: str, reg: int, imm: int):
    inst = inst.removesuffix('x')
    op = INSTRUCTIONS[inst]
    reject(not isinstance(reg, int) or not (0 <= reg < 8))
    if op < 12:
        reject(not isinstance(imm, int) or not (-16 <= imm < 16))
    else:
        reject(not isinstance(imm, int) or not (0 <= imm < 31))
    return build((0b0101, 4), (op, 4), (reg, 3), (imm & 0x1F, 5))


@base.inst('/inpx/ register "," immediate', strict=True)
@base.inst('/inpx?/ register "," immediate', strict=False)
def base_inp(context, _, reg, port):
    reject(not isinstance(reg, int) or not (0 <= reg < 8))
    reject(not isinstance(port, int) or not (0 <= port < 16))
    return build((0b0101, 4), (0xE, 4), (reg, 3), (port, 4), (1, 1))


@base.inst('/outx/ register "," immediate', strict=True)
@base.inst('/outx?/ register "," immediate', strict=False)
def base_out(context, _, reg, port):
    reject(not isinstance(reg, int) or not (0 <= reg < 8))
    reject(not isinstance(port, int) or not (0 <= port < 16))
    return build((0b0101, 4), (0xF, 4), (reg, 3), (port, 4), (1, 1))


@base.inst('/mfcrx/ register "," immediate', strict=True)
@base.inst('/mfcrx?/ register "," immediate', strict=False)
def base_mfcr(context, _, reg, port):
    reject(not isinstance(reg, int) or not (0 <= reg < 8))
    reject(not isinstance(port, int) or not (0 <= port < 16))
    return build((0b0101, 4), (0xE, 4), (reg, 3), (port, 4), (0, 1))


@base.inst('/mtcrx/ register "," immediate', strict=True)
@base.inst('/mtcrx?/ register "," immediate', strict=False)
def base_mtcr(context, _, reg, port):
    reject(not isinstance(reg, int) or not (0 <= reg < 8))
    reject(not isinstance(port, int) or not (0 <= port < 16))
    return build((0b0101, 4), (0xF, 4), (reg, 3), (port, 4), (0, 1))


JUMP_NAMES = {
    "z": 0,
    "nz": 1,
    "n": 2,
    "nn": 3,
    "c": 4,
    "nc": 5,
    "v": 6,
    "nv": 7,
    "be": 8,
    "a": 9,
    "l": 10,
    "ge": 11,
    "le": 12,
    "g": 13,
    "mp": 14,
}


@base.inst(f'/j{oneof(*JUMP_NAMES)}/ label', strict=False)
def base_jumps(context, inst: str, label: str):
    inst = inst.removeprefix('j')
    op = INSTRUCTIONS[inst]
    target = context.resolve_label(label) - context.current_position
    reject(not (-256 <= target < 256))
    return build((0b100, 3), (target & 100 >> 8, 1), (op, 4), (target & 0xFF, 8))


@base.inst('"nop"')
def base_nop(context):
    return b"\x8f\x00"  # jump nowhere, never
