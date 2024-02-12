#!/usr/bin/env python3
import sys


def parse_table(i, s: str):
    out = {}
    for line in s.splitlines():
        if not line.strip():
            continue
        _, idx, name, abbr, *_ = line.split('|')
        out[abbr.lower().strip()] = i, int(idx), name.strip()
    return out


table_cpuid1 = parse_table(0, """
|     0      | [Full Immediate](./full-immediates)                       |  FI  |      VWI      | Under Development |
|     1      | [Stack & Functions](./stack-and-functions)                | SAF  |     None      | Mostly Stable     |
|     2      | [Interrupts](./interrupts)                                | INT  |  CP1.1, FT.0  | Under Development |
|     3      | [8 Bit Operations + Registers](./half-word-operations)    | BYTE |     None      | Mostly Stable     |
|     4      | [Conditional Execution](./conditional-prefix)             | COND |      VWI      | Under Development |
|     5      | [Expanded Registers](./expanded-registers)                | REX  |      VWI      | Under Development |
|     6      | [Cache Instructions](./cache-instructions)                |  CI  |     None      | Under Development |
|     7      | [Arbitrary Stack Pointer](./arbitrary-stack-pointer)      | ASP  |     CP1.1     | Under Development |
|     13     | [Memory Operands 2](./memory-operands-2)                  | MO2  |      VWI      | Under Development |
|     14     | [32 Bit Operations + Registers](./double-word-operations) |  DW  |     None      | Mostly Stable     |
|     15     | [64 Bit Operations + Registers](./quad-word-operations)   |  QW  |     None      | Mostly Stable     |
|     16     | [32 Bit Address Space](./32-bit-address-space)            | DWAS |    CP1.14     | Under Development |
|     17     | Virtual Memory + 16 Bit Paging                            | PG16 | CP1.16, CP2.2 | Planned           |
|     18     | Virtual Memory + 32 Bit Paging                            | PG32 | CP1.16, CP2.2 | Planned           |
|     32     | [64 Bit Address Space](./64-bit-address-space)            | QWAS |    CP1.15     | Under Development |
|     33     | Virtual Memory + 64 Bit Paging (48 bit VA)                | PG48 | CP1.32, CP2.2 | Planned           |
|     34     | Virtual Memory + 64 Bit Paging (57 bit VA)                | PG57 | CP1.32, CP2.2 | Planned           |
|     35     | Virtual Memory + 64 Bit Paging (64 bit VA)                | PG64 | CP1.32, CP2.2 | Planned           |
""")
table_cpuid2 = parse_table(1, """
|     0      | [Expanded Opcodes](./expanded-opcodes)       | EXOP |      VWI      | Under Development |
|     1      | [Memory Operands 1](./memory-operands-1)     | MO1  |      VWI      | Under Development |
|     2      | [Privileged Mode](./privileged-mode)         | PM   |     CP1.2     | Under Development |
|     3      | [Multiply Divide](./multiply-divide)         | MD   |     CP2.0     | Under Development |
|     4      | Bit Manipulation 1                           | BM1  |     CP2.0     | Planned           |
""")
table_feat = parse_table(2, """
|     0     | [Von Neumann](./von-neumann)                                                 | VON  | Mostly Stable     |
|     1     | [Unaligned Memory Access](./unaligned-memory)                                | UMA  | Mostly Stable     |
|     2     | [Cache Coherency](./cache-coherency)                                         | CC   | Under Development |
|     3     | [Multiple Memory Access Instructions](./multiple-memory-access-instructions) | MMAI | Mostly Stable     |
""")

full_table = {**table_cpuid1, **table_cpuid2, **table_feat}

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <abbr-string>")
        exit(1)
    res = [0,0,0]
    for abbr in sys.argv[1].split(','):
        if abbr.lower() not in full_table:
            raise ValueError(f"Unknown Extension/Feature {abbr}")
        i, idx, name = full_table[abbr.lower()]
        res[i] |= (1 << idx)
        print(name)
    print(f"{res[0]:X}.{res[1]:X}.{res[2]:X}")


if __name__ == '__main__':
    main()
