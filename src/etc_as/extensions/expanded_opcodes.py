from etc_as.core import Extension, reject, oneof
from etc_as.base_isa import build, validate_registers, CONDITION_NAMES

# it's actually cp2.0 ...
expanded_opcodes = Extension(0, "exopc", "Expanded Opcodes")

def encode_reg_operation(cxt, inst, opc, size, regA, regB):
    size, (A, B) = validate_registers(cxt, regA, regB, inst_size=size)
    opc_high = (opc & 0b111110000) >> 4
    opc_low  = opc & 0xF
    return build((0xE,4), (opc_high, 5), (0, 1),
                 (size, 2), (opc_low, 4),
                 (A, 3), (B, 3), (0, 2))

def encode_imm_operation(cxt, inst, opc, size, regA, imm, imm_signed):
    size, (A,) = validate_registers(cxt, regA, inst_size=size)
    opc_high = (opc & 0b111110000) >> 4
    opc_low  = opc & 0xF

    if imm_signed:
        reject(not isinstance(imm, int) or not (-16 <= imm < 16),
               f"Invalid immediate {imm} for opcode {inst}")
    else:
        reject(not isinstance(imm, int) or not (0 <= imm < 32), f"Invalid immediate {imm} for opcode {inst}")

    return build((0xE,4), (opc_high, 5), (1, 1),
                 (size, 2), (opc_low, 4),
                 (A, 3), (imm, 5))

INSTRUCTIONS = {
    "adc": 0,
    "sbb": 1,
    "rsbb": 2
}

@expanded_opcodes.inst(f'/{oneof(*INSTRUCTIONS)}/ size_postfix register "," register')
def exopc_reg_reg(cxt, inst: str, inst_size: str | None, a, b):
    return encode_reg_operation(cxt, inst, INSTRUCTIONS[inst], inst_size, a, b)

@expanded_opcodes.inst(f'/{oneof(*INSTRUCTIONS)}/ size_postfix register "," immediate')
def exopc_reg_imm(cxt, inst: str, inst_size: str | None, a, imm: int):
    return encode_imm_operation(cxt, inst, INSTRUCTIONS[inst], inst_size, a, imm, True)

@expanded_opcodes.inst(f'/j{oneof(*CONDITION_NAMES, exclude=("",))}/ symbol')
def base_jumps(context, inst: str, symbol: tuple[int, str]):
    inst = inst.removeprefix('j')
    op = CONDITION_NAMES[inst]
    target = context.resolve_symbol(symbol)
    if target is None:
        target = context.ip

    offset = target - context.ip
    # I tried to do something fancy with bit_length but on negative numbers it gives
    # you the length of the negation... which is wrong at the edge cases :(
    size = None
    if (-128 <= offset < 128):
        size = 0
    elif (-(2**15) <= offset < 2**15):
        size = 1
    elif (-(2**31) <= offset < 2**31) and cxt.ip_mask >= 0xFFFF_FFFF:
        size = 2
    elif cxt.ip_mask >= 0xFFFF_FFFF_FFFF_FFFF:
        size = 3

    if size is None:
        raise ValueError(f"Offset {offset} is bigger than the address space?")

    return build((0x7, 3), (2, 2), (0, 1), (size, 2)) + offset.to_bytes(2**size, 'little', signed=True)

