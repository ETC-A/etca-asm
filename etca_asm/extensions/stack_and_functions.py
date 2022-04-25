from etca_asm.core import Extension, reject, oneof
from etca_asm.base_isa import CONDITION_NAMES, validate_registers, build

functions = Extension(2, "functions", "Stack and Functions")
Register = tuple[int | None, int]

REGISTERS = {
    "a0": 0,
    "a1": 1,
    "a2": 2,
    "s0": 3,
    "s1": 4,
    "bp": 5,
    "sp": 6,
    "ln": 7,
}

@functions.reg(fr'"%" /(bp|sp|ln)/ size_postfix')
@functions.reg(fr'/(bp|sp|ln)/ size_postfix', prefix=False)
def fn_ptr_registers(cxt, name, size):
    return size, REGISTERS[name]

@functions.reg(fr'"%" /(a|v|s)/ size_infix /(?!<\s)[0-2]/')
#@functions.reg(fr'/(a|v|s)/ size_infix /[0-1]/', prefix=False)
@functions.reg(fr'/(a|v|s)/ size_infix /(?!<\s)[0-2]/', prefix=False)
def fn_gp_registers(cxt, pref, size, suff):
    name = pref + suff
    reject(not name in REGISTERS.keys(), f"Unknown register name `{name}'")
    return size, REGISTERS[name]

@functions.inst(f'"pop" size_postfix register')
def pop_inst(cxt, inst_size, reg: Register):
    size, (dst,) = validate_registers(cxt, reg, inst_size=inst_size)
    return build((0b00,2), (cxt.register_sizes[size],2), (0xC,4), (dst,3), (6,3), (0b00,2))

@functions.inst(f'"push" size_postfix register')
def push_register_inst(cxt, inst_size, reg: Register):
    size, (src,) = validate_registers(cxt, reg, inst_size=inst_size)
    return build((0b00,2), (cxt.register_sizes[size],2), (0xD,4), (6,3), (src,3), (0b00,2))

@functions.inst(f'"push" size_postfix immediate')
def push_register_imm(cxt, inst_size, imm: int):
    size, () = validate_registers(cxt, inst_size=inst_size)
    reject(
        not isinstance(imm, int) or not (0 <= imm < 32),
        f"Invalidate immediate {imm} for op `push'"
    )
    return build((0b01,2), (cxt.register_sizes[size],2), (0xD,4), (6,3), (imm,5))

@functions.inst(f'/j{oneof(*CONDITION_NAMES)}/ register')
def cond_abs_reg_jump(cxt, inst: str, reg: Register):
    _,(src,) = validate_registers(cxt, reg)
    cc = inst.removeprefix('j')
    op = CONDITION_NAMES[cc]
    return build((0xAF,8), (src,3), (0b0,1), (op,4))

@functions.inst(f'/ret{oneof(*CONDITION_NAMES)}/')
def cond_return(cxt, inst: str):
    cc = inst.removeprefix('ret')
    reject(cc == 'mp', "`mp' is not a valid conditional return suffix")
    op = CONDITION_NAMES[cc]
    return build((0xAF,8), (0b111,3), (0b0,1), (op,4))

@functions.inst(f'/call{oneof(*CONDITION_NAMES)}/ register')
def cond_abs_reg_call(cxt, inst: str, reg: Register):
    _,(src,) = validate_registers(cxt, reg)
    cc = inst.removeprefix('call')
    reject(cc == 'mp', "`mp' is not a valid conditional call suffix")
    op = CONDITION_NAMES[cc]
    return build((0xAF,8), (src,3), (0b1,1), (op,4))

@functions.inst('"call" symbol')
def rel_near_imm_call(cxt, lbl: str):
    target = cxt.resolve_symbol(lbl)
    if target is None:
        offset = 0
    else:
        offset = target - cxt.ip
    bottom_mask = 0xfff
    reject(
        offset < -2048 or offset > 2047,
        f"""Cannot encode near call:
    from `call {lbl}'     at 0x{cxt.ip:04x}
    to   `{lbl}' resolved to 0x{offset:04x}"""
    )
    return build((0xB,4), (bottom_mask & offset, 12))
