# all syntax in this file is speculative
from etc_as.core import Extension
from etc_as.base_isa import build

cache = Extension(6, "cachecontrol", "Cache Instructions")

@cache.inst(f'"clzero" register')
def alloc_zero_inst(cxt, reg):
    return build((15, 8), (0b010,3), (reg[1], 3), (0, 2))

@cache.inst(f'"invdda" register')
def invalidate_dcache_by_address(cxt, reg):
    return build((15, 8), (0b011,3), (reg[1], 3), (0, 2))

@cache.inst(f'"invdia" register')
def invalidate_icache_by_address(cxt, reg):
    return build((0x9F, 8), (0, 3), (reg[1], 3), (3, 2))

@cache.inst(f'"cflush"')
def cache_flush(cxt):
    return bytes([0x8F, 0x01])

@cache.inst(f'"invd"')
def cache_invalidate(cxt):
    return bytes([0x8F, 0x02])

@cache.inst(f'"prefetchd" register')
def data_prefetch(cxt, reg):
    return build((0x9F, 8), (0, 3), (reg[1], 3), (0, 2))

@cache.inst(f'"prefetchi" register')
def inst_prefetch(cxt, reg):
    return build((0x9F, 8), (0, 3), (reg[1], 3), (1, 2))

@cache.inst(f'"clflush" register')
def cache_line_flush(cxt, reg):
    return build((0x9F, 8), (0, 3), (reg[1], 3), (2, 2))
