;
.extensions byte_operations, dword_operations, functions

;;; Hand-compiled from asm_loader_kernel.c
;;; I won't copy all of the comments from that file but the general ideas are important.
;;;
;;; Addresses 0-31 are MMIO:
;;;   0: unused by this program
;;;   1: A read-only file stream. This is the input. Reading from this address should
;;;      cause a single character to be read from the stream and the stream to be
;;;      advanced. This program does not require any seeking functionality.
;;;      The end of textual files should be indicated by the character '\0'.
.set STREAM 1
;;;   2: When this address is read from, the user should be queried for a mode, which
;;;      should be given back to the program. Currently, the only understood mode is
;;;      mode 0, which reads the filestream as a textual file and assembles its contents.
;;;      The assembled program is then invoked. See asm_loader_kernel.c for details.
;;;      Note to users in TC: the current version only queries the mode once, so you can
;;;      hardware this I/O to a constant if you like.
.set MODEQ 2
;;;   3: Some form of output system. The program will send bytes to this address when
;;;      the corresponding ASCII character should be printed to the output.
.set OUTPUT 3


;;; Memory between 0x0020 and 0x777F must be RAM.
;;; Memory from 0x8000 to 0xBFFF should be this program ROM.
;;; Memory from 0xC000 to 0xFFFF should again be RAM.

;;; ********************************************************************************
;;; *********************** Main Implementation Comments ***************************
;;; ********************************************************************************

;;; Addresses [0x0020, 0x0030) are used as a buffer for reading symbols and some
;;; other things. The size of symbols cannot exceed 16 characters. The program defends
;;; against buffer overflow.
;;;
;;; Addresses from 0x0030 and up are the destination for the assembled program.
;;; Addresses from 0x7FFE and down are used to hold a relocation table for the second pass.
;;; Addresses in [0xC000,0xC020) are used to hold a "static data" segment. The program
;;;   keeps a pointer to 0xC010 for fast access to this segment. More information about
;;;   its layout follows.
;;; Addresses from 0xC020 and up are used to hold a symbol table. This puts a physical
;;;   limit of about 500 symbols on the input file. In practice, that should be plenty.
;;;   Addresses from 0xFFFF and down are used for the kernel stack. The call tree never
;;;   gets very deep, but stack use internal to the functions might be noticeable.
;;;   I'm not sure yet.
;;;
;;; **The kernel stack is only kept word-aligned. 32 bit data might be clobbered
;;;   by function calls, even if the function says it does not clobber that register!**


;;; This file does not use one consistent calling convention. *In general*, you can expect
;;;   r0: first argument
;;;   r1: second argument
;;;   r2: third argument
;;;   r3: fourth argument
;;;   r4: callee-saved
;;;   r5: pointer to 0xC010 if at a stage where this pointer should be kept around
;;;       but sometimes, like during lexing/parsing, we do not need this pointer.
;;;       Then, r5 is a second callee-saved register.
;;;   r6: stack pointer. I will probably only ever refer to this register as %sp.
;;;   r7: link register.
;;;
;;; However, there are a few functions with different calling conventions, which are
;;; documented. Some do not clobber any registers other than those containing the
;;; function arguments (usually only r0 and r1, possibly r2).
;;; Another group of functions expects to be tail-called through a jump table. They
;;; all have 5 arguments. They take their arguments in r0-r4. r5 must be the 0xC010 pointer.
;;; r6 is still their stack pointer. r7 will contain their own address, as it should be used
;;; to call them through the pointer. However, they should not rely on this fact, since a
;;; couple of them are also called from elsewhere. They expect their return address on top
;;; of the stack. Those that are called from elsewhere have a secondary entry point which
;;; pushes %ln.


;;; ********************************************************************************
;;; ****************************** Static Data Layout ******************************
;;; ********************************************************************************

;;;                  asm time         run time
;;;              __________________________________
;;; 0xC00A      |  uint16_t src_lineno |  user %sp |
;;;             |----------------------------------|
;;; 0xC00C      |  reloc_t *relocation_table_top   |
;;;             |----------------------------------|
;;; 0xC00E      |  reloc_t *relocation_table_bot   |
;;;             |----------------------------------|
;;; 0xC010      |   instr *asm_ip  |  void *break  |
;;;             |----------------------------------|
;;; 0xC012      |     table_entry symtab_root      |
;;;             |----------------------------------|
;;; 0xC014      |     table_entry symtab_end       |
;;;             |----------------------------------|
;;; 0xC016      |   char eol_char  |       ?       |
;;;             |__________________|_______________|

.set SRCLINENO_OFS     -6
.set RELOC_TAB_TOP_OFS -4
.set RELOC_TAB_BOT_OFS -2
; no value set for ASM_IP_OFS, so that I get an error if I am stupid and try to use it :)
.set SYMTAB_ROOT_OFS    2
.set SYMTAB_END_OFS     4
.set EOL_CHAR_OFS       6

.set STATIC_DATA_PTR    0xC010
.set INIT_SYMTAB_ROOT   0xC020
.set INIT_STK_PTR       0xFFFE   ; word-aligned, I don't think we ever need to put 32-bit data on the stack
.set INIT_OBJ_STK_PTR   0x7FFC   ; dword-aligned, as that is the promise we make to the object program

.set BUFFER_PTR         0x0020
.set CODE_SEGMENT       0x0030
.set RELOC_TAB_TOP      0x8000   ; past the end

;;; ********************************************************************************
;;; ********************************* THE PROGRAM **********************************
;;; ********************************************************************************

            call    _start

; I have no clue what the layout needs to look like to keep related things close together.
; For now I'm just writing functions as I feel like, where I feel like.


object_return_stub:
            mov     %r0, 0                  ; SYSCALL_EXIT
            mov     %r1, 0                  ; STATUS_OK
syscall:
            cmph    %r0, 4                  ; biggest known syscall is 4.
            jbe     good_service_no         ; service <= 4? if yes, keep going. Otherwise, exit 140
            mov     %r0, 0
            mov     %r1, 140                ; exit code 140, SIGSYS
            jmp     syscall
good_service_no:
            testx   %sp, 1                  ; test the bottom stack bit. The ABI requires that this
                                            ; bit be 0, so that the called function can at least
                                            ; save the 16-bit return address.
            jz      aligned_stack           ; crash the program with code 139 (segfault) if it's on
            andx    %sp, -2                 ; align the stack so that we don't weirdloop
            mov     %r0, 0
            mov     %r1, 139
            jmp syscall
aligned_stack:
            stx     %ln, %sp                ; the stack is now guaranteed to be aligned. Save %ln.
                                            ; But without pushing, so that we save the right %sp.
            mov     %ln, 0xC00A             ; &static_data->user_sp
            stx     %sp, %ln                ; static_data->user_sp = %sp
            ldx     %ln, %sp                ; restore our return address
            mov     %sp, INIT_STK_PTR       ; initialize our own stack
            pushx   %ln                     ; and save our return address there.
            call    syscall_with_table      ; get the syscall table
            ; all of these functions are implemented down at the bottom
            .word   syscall_exit syscall_putuint syscall_putsint syscall_puts syscall_sbrk
syscall_with_table:
            addh    %r0, %r0                ; service_no *= sizeof(word)
            addx    %ln, %r0                ; offset into the syscall table
            ldx     %ln, %ln                ; load the system function to call
            jmp     %ln                     ; invoke it


; The assembler/bootloader entrypoint.
_start:
            mov     %r5, STATIC_DATA_PTR
            mov     %r6, INIT_STK_PTR
            movz    %r0, 16
            addx    %r0, %r5                ; INIT_SYMTAB_ROOT is STATIC_DATA_PTR+16
            movx    %r1, %r5
            addx    %r1, 2                  ; &static_data.symtab_root
            stx     %r0, %r1
            addx    %r1, 2
            stx     %r0, %r1                ; static_data->symtab_root = static_data->symtab_end = STATIC_DATA_PTR+16
            sub     %r1, 6                  ; &static_data.reloc_tab_bot
            mov     %r0, RELOC_TAB_TOP
            stx     %r0, %r1                ; static_data->reloc_tab_bot = RELOC_TAB_TOP
            sub     %r1, 2                  ; &static_data.reloc_tab_top
            stx     %r0, %r1                ; static_data->reloc_tab_top = RELOC_TAB_TOP
            sub     %r1, 2                  ; &static_data.src_lineno
            mov     %r0, 1                  ; initial line is line 1
            stx     %r0, %r1                ; static_data->src_lineno = 1
            mov     %r0, CODE_SEGMENT       ; initial code segment ip
            stx     %r0, %r5                ; static_data->asm_ip = CODE_SEGMENT

            call    assemble_fp
            call    assemble_sp
            call    get_start_stub
            .asciiz "_start"
            .align  2
get_start_stub:
            movx    %r0, %ln                ; arg 0 = "_start"
            call    find_table_entry        ; find (or create, boo) a table entry for "_start"
            call    sp_get_symbol           ; xlookup the address for _start
            pushx   %r0                     ; stash that while we clean up

            mov     %r0, completed_assembly_msg
            mov     %ln, puts
            call    %ln                     ; inform the user that their program is starting soon
                                            ; at this point, it is time to hang up our hat and give
                                            ; control to the object program. We made a few promises
                                            ; that we have to keep with regards to initialization.
                                            ; We should set the return address to a function that exits
                                            ; successfully. %r0 should be a pointer to the syscall
                                            ; function. The stack pointer needs to be initialized.
                                            ; All other registers should be cleared.
            mov     %ln, object_return_stub
            mov     %r0, 4                  ; syscall - object return stub
            addx    %r0, %ln                ; r0 = syscall
            popx    %r1                     ; reload address of _start to prepare transfer of control
            mov     %sp, INIT_OBJ_STK_PTR   ; initialize the object program stack pointer
            mov     %r2, 0
            mov     %r3, 0
            mov     %r4, 0
            mov     %r5, 0
            jmp     %r1                     ; give control to the object program!


; shr4 and shr5 functions
;   r0: x
;   r1: width
; returns r0: (x >> {4/5}) & (2^width - 1)
; clobbers r1
; r2-r7 unchanged
; Worth looking into whether saving r2/r3 here is worth it. Comment in the C
; code said it would be, but that comment was written long before the callsites.


shr5:
            pushx   %r2      ; having separated vaneers like this is fewer instructions
            movzx   %r2, 16  ; I have optimized for the placement of shr4 here.
            addx    %r2, %r2        ; 16 + 16 = 32
            jmp     shr_L1
shr4:
            pushx   %r2
            movzx   %r2, 16
shr_L1:
            pushx   %r3
            movd    %r3, %r0        ; move x to r3
            pushx   %r4
            mov     %r4, 1          ; b = 1
            xor     %r0, %r0        ; clear r0 (it holds 'r')
shr_L2:                             ; top of shr loop
            testd   %r2, %r3        ; test mask & x
            jz      shr_L3          ; don't set bit of r if !(mask & x)
            ord     %r0, %r4        ; r |= b if mask & x, shifts that bit over
shr_L3:
            addd    %r2, %r2        ; mask <<= 1
            cmpd    %r2, %r3        ; mask >? x
            ja      shr_L4          ; if yes, further testds will fail and we can quit.
            addd    %r4, %r4        ; b <<= 1
            subh    %r1, 1          ; --width
            jnz     shr_L2          ; loop if width != 0
shr_L4:
            pop     %r4             ; now r0 has the result
            pop     %r3               ; so we can unwind
            pop     %r2
            ret

; shl
;   r0: number to shift
;   r1: amount to shift left
; returns
;   r0: shifted number
;   r1: 0
; All other register are unchanged.
shl_L1:
            addd    %r0, %r0        ; x <<= 1
shl:
            subh    %r1, 1          ; --shamt
            jnn     shl_L1          ; exec loop if --shamt >= 0 === shamt > 0
            ret

; strncmp
;   r0: const char *a
;   r1: const char *b
;   r2: int16_t     n
; returns:
;   r0: 0 if strings at *a and *b compare equal, nonzero otherwise
;   r1: b + however many characters were compared
;   r2: n - however many characters were compared
; clobbers: r0, r1, r2
; r3-r7 unchanged
;
; Compare the strings at *a and *b, terminating when they disagree,
; when they have both ended (nul-terminated), or after 'n' characters.
; If you give n as 0, it the first characters will still be compared.
; This saves one instruction byte in the implementation.
;
; A result of the way %r1 and %r2 are handled is that after the function
; returns, it is guaranteed that %r1 + %r2 will give the same result as
; it would have given before the strncmp call. This can be used to avoid
; saving the second argument to the stack.
strncmp:
            pushx   %r3             ; wind stack, giving two free registers
            pushx   %r4             ; which we will use to hold *a and *b
strncmp_L1:                         ; top of loop
            ldh     %r3, %r0        ; r3 = *a
            ldh     %r4, %r1        ; r4 = *b
            subh    %r4, %r3        ; subtract *a from *b
            jne     strncmp_L2      ; return if *a != *b
            testh   %r3, -1         ; test *a
            jz      strncmp_L2      ; also return if *a == 0 (note *b - *a still in %r4)

            addd    %r0, 1          ; ++a
            addd    %r1, 1          ; ++b
            subd    %r2, 1          ; --n
            jg      strncmp_L1      ; if n is > 0, loop
strncmp_L2:                         ; return label
            movh    %r0, %r4        ; return value is *b - *a
            popx    %r4             ; unwind stack
            popx    %r3
            ret

;;; ********************************************************************************
;;; ******************************** SYMBOL TABLE **********************************
;;; ********************************************************************************

;;; each entry must be 4-byte aligned for "rapid" copying into the table.
;;; Each entry is a 16-byte string (not necessarily nul-terminated!) followed by
;;; a 4-byte payload. The total size of an entry is 20 bytes. There is no metadata.

; find_table_entry
;   r0:  symbol name
;   r5:  must be the static data pointer!
; returns
;   r0:  a pointer to a symbol table entry for 'name' which might be newly added
;   r3:  0 if the returned entry is new, otherwise static_data->symtab_end
; Registers r1-r3 are clobbered.
find_table_entry:
            pushx   %ln                 ; we call functions so we have to save this
            movx    %r3, %r5            ; copy &static_data
            addx    %r3, SYMTAB_ROOT_OFS; r3 = &static_data.symtab_root
            ldx     %r1, %r3            ; r1 = static_data->symtab_root
            addx    %r3, 2              ; r3 = &static_data.symtab_end
            ldx     %r3, %r3            ; r3 = static_data->symtab_end
                                        ; we choose r3 for this because strncmp does not clobber r3
            jmp     find_table_entry_L3
find_table_entry_L1:                    ; loop top
                                        ; ste is in r1, top is in r3, name is in r0
                                        ; note the guarantee of strncmp: across calls to it,
                                        ; r1 + r2 is invariant! this is very useful.
            movz    %r2, 16             ; third argument = 16, first two are already name,ste
            pushx   %r0                 ; save name
            pushx   %r1                 ; save ste
            call    strncmp             ; r0 = !(name `streq` ste->symbol), r1 = r1 + N, r2 = r2 - N
            test    %r0, -1             ; set Z flag if (name `streq` ste->symbol)
            popx    %r0                 ; restore ste
            jnz     find_table_entry_L2 ; if we missed on the table, skip return and keep going
            addx    %sp, 2              ; pop name off the stack, w/out restoring it
            popx    %ln                 ; restore return address
            ret                         ; return ste
find_table_entry_L2:
            popx    %r0                 ; restore name
            addx    %r1, %r2            ; invariant guarantee tells us that r1 now is ste + 16
            addx    %r1, 4              ; ste = ste + 20
find_table_entry_L3:
            cmpx    %r1, %r3            ; compare ste against symtab end
            jb      find_table_entry_L1 ; loop as long as ste < symtab end
            mov     %r1, 0              ; argument 1 = 0
            popx    %ln                 ; restore return address
            ;;; jmp     add_table_entry     ; tail-call add_table_entry (by falling through)

; add_table_entry
;   r0:  symbol  name   (symbol = char*)
;   r1:  int32_t payload
;   r5:  must be the static data pointer!
; returns
;   r0:  address of new entry
;   r1:  pointer to static_data.symtab_end
;   r2:  final value of static_data->symtab_end
;   r3:  guaranteed to be 0
; Other registers are unchanged.
add_table_entry:
            pushx   %r4                 ; wind a saved register
            movx    %r2, %r5            ; char *ptr = &static_data
            addx    %r2, SYMTAB_END_OFS ; ptr = &static_data.symtab_end
            pushx   %r2                 ; spill this address for quick retrieval
            ldx     %r2, %r2            ; ptr = static_data->symtab_end
            mov     %r3, 4              ; i = 4
add_table_entry_L1:
            ldd     %r4, %r0            ; temp = *name, 32-bit transfer
            std     %r4, %r2            ; *ptr = *name, 32-bit transfer
            addx    %r0, 4              ; name += 4
            addx    %r2, 4              ; ptr  += 4
            sub     %r3, 1              ; --i
            jnz     add_table_entry_L1  ; loop until i == 0

            std     %r1, %r2            ; *ptr = payload
            addx    %r2, 4              ; ptr += 4
            popx    %r1                 ; r1 = &static_data.symtab_end (spilled earlier)
            ldx     %r0, %r1            ; return value = static_data->symtab_end
            stx     %r2, %r1            ; static_data->symtab_end = ptr
            popx    %r4                 ; unwind
            ret

; ste_attach_payload
;   r0:  symbol  name
;   r1:  uint16_t payload
; returns
;   r0:  &entry.payload for the entry for 'name'
; Clobbers r2 and r3. The payload remains in r1.
;
; This function disagrees with the C code slightly. IT CAN ONLY ATTACH 16-BIT PAYLOADS.
; This is all we use it for anyway, but it needs to be noted.
ste_attach_payload:
            pushx   %ln                 ; save return address
            pushx   %r1                 ; save payload
            call    find_table_entry    ; r0 = entry for 'name'
            movz    %r1, 16             ; r1 = offsetof(table_entry, payload)
            addx    %r0, %r1            ; r0 = &entry.payload
            popx    %r1                 ; r1 = payload
            stx     %r1, %r0            ; entry->payload = payload
            popx    %ln
            ret

; ste_get_payload
;   r0:  table_entry entry: entry from which to get payload
; returns
;   r0:  uint16_t payload from that entry
; No registers are clobbered.
; Only 16-bit payloads can be retrieved. Do not rely on the value being
; zero extended or sign extended, either.
ste_get_payload:
            addx    %r0, 8
            addx    %r0, 8              ; 16 is too large for add, so add 8 twice
            ldx     %r0, %r0            ; entry->payload
            ret

;;; ********************************************************************************
;;; *************************** ASSEMBLER IMPLEMENTATION ***************************
;;; ********************************************************************************

;;; ********************************** FIRST PASS **********************************

assemble_fp:
            pushx   %ln
assemble_fp_L1:
            call    fpsm
            movx    %r0, %bp            ; r0 = &static_data
            addx    %r0, SRCLINENO_OFS  ; r0 = &static_data.src_lineno
            ldx     %r1, %r0            ; r1 = static_data->src_lineno
            addx    %r1, 1
            stx     %r1, %r0            ; static_data->src_lineno++
            addx    %r0, 4              ; r0 = &static_data.reloc_tab_bot
            ldx     %r1, %r0            ; r1 = static_data->reloc_tab_bot
            ldx     %r2, %bp            ; r2 = static_data->asm_ip
            cmpx    %r2, %r1            ; asm_ip >? reloc_tab_bot
            jbe     assemble_fp_L2      ; if no, don't die
            mov     %r0, 4              ; arg 0 = OUT_OF_MEMORY_CODE
            call    die
assemble_fp_L2:
            addx    %r0, 8              ; r0 = &static_data.eol_char
            ldh     %r0, %r0            ; r0 = static_data->eol_char
            testh   %r0, -1             ; test the char
            jnz     assemble_fp_L1      ; loop if it's not \NUL
            popx    %ln                 ; if it's \NUL, we're done.
            ret

;;; ********************************* SECOND PASS **********************************

assemble_sp:
            pushx   %ln
            ldx     %r0, %bp            ; r0 = static_data->asm_ip
            pushx   %r0                 ; save ip at end of program
            mov     %r0, SRCLINENO_OFS
            addx    %r0, %bp            ; r0 = &static_data.src_lineno
            ldx     %r0, %r0            ; r0 = static_data->src_lineno
            pushx   %r0                 ; save final lineno (idk why but hey)
            mov     %r0, RELOC_TAB_BOT_OFS
            addx    %r0, %bp            ; r0 = &static_data.reloc_tab_bot
            ldx     %r2, %r0            ; r2 = reloc_entry = static_data->reloc_tab_bot
            testx   %r2, -1             ; test the pointer to see if it's negative
            jn      assemble_sp_L2      ; skip the loop entirely if so
assemble_sp_L1:
            pushx   %r2                 ; save original value of reloc_entry
            ldx     %r1, %r2            ; r1 = arg 1 = reloc_entry->asm_ip
            stx     %r1, %bp            ; static_data->asm_ip = reloc_entry->asm_ip
            addx    %r2, 4              ; &reloc_entry.src_lineno
            ldx     %r0, %r2            ; r0 = reloc_entry->src_lineno
            mov     %r3, SRCLINENO_OFS
            addx    %r3, %bp            ; r3 = &static_data.src_lineno
            stx     %r0, %r3            ; static_data->src_lineno = reloc_entry->src_lineno
            subx    %r2, 2              ; &reloc_entry.entry
            ldx     %r0, %r2            ; arg 0 = reloc_entry->entry
            call    assemble_sp_visit   ; handle this reloc table entry
            popx    %r2                 ; reload original value of reloc_entry
            addx    %r2, 6              ; advance to next entry
            jnn     assemble_sp_L1      ; if result is not negative, it's a valid entry. Loop.
assemble_sp_L2:
            popx    %r0                 ; restore final lineno
            mov     %r1, SRCLINENO_OFS
            addx    %r1, %bp            ; &static_data.src_lineno
            stx     %r0, %r1            ; static_data->src_lineno = saved original lineno
            popx    %r0                 ; restore ip at end of program
            stx     %r0, %bp            ; static_data->asm_ip = ip at end of program
            popx    %ln                 ; restore return address
            ret

; assemble_sp_visit
;   r0: table_entry ste
;   r1: asm_ip
; no returns
; Clobbers whatever it feels like.
;
; Visit the instruction referenced by a relocation table entry.
assemble_sp_visit:
            pushx   %ln
            call    sp_get_symbol       ; arg 0 = target = sp_get_symbol(ste)
            ldh     %r2, %r1            ; opc = *asm_ip
            cmph    %r2, -1             ; test if opc is -1
            jne     assemble_sp_visit_tx; if it's not, it's a control transfer
            addx    %r1, 1              ; asm_ip + 1
            ldh     %r2, %r1            ; r2 = reg = *(asm_ip+1)
            movx    %r1, %r0            ; arg 1 = target
            movh    %r0, %r2            ; arg 0 = reg
            call    assemble_long_mov   ; tail-call (it won't be returning here)
assemble_sp_visit_tx:
            cmph    %r2, 15             ; opc >? 15
            ja      fp_call_L           ; if yes, this is a call
            jmp     fp_jump_L           ; otherwise, it's a jump
                ; those are both tail-calls. They will return via the %ln
                ; we put on top of the stack, to just above assemble_sp_L2.

; *********************** UTILITIES ***********************

; fp_get_symbol
;   r0: symbol name
;   r5: &static_data
; returns
;   r0: uint16_t the payload from the symbol table entry for that symbol
; Clobbers r1 and r3.
;
; If an entry for the name does not exist, one will be added. In this case, the
; returned payload will be 0, and an entry will be added to the relocation table
; to indicate that the instruction assembled at the current static_data->asm_ip
; needs to be revisited later.
fp_get_symbol:
            pushx   %ln
            pushx   %r2                 ; stack wind
            call    find_table_entry    ; r0 = entry = find_table_entry(name)
                                        ; clobber(r1,r2,r3)
            pushx   %r0                 ; spill entry
            call    ste_get_payload     ; r0 = ste_get_payload(entry)
            testx   %r0, -1             ; check the returned payload value
            jnz     fp_get_symbol_unwind; if it's not 0, we're done.
                                        ; if it is zero, we have to add an entry to
                                        ; the relocation table:
            mov     %r1, %bp            ; r1 = copy &static_data
            addx    %r1, RELOC_TAB_BOT_OFS ; r1 = &static_data.reloc_tab_bot
            ldx     %r2, %r1            ; r2 = static_data->reloc_tab_bot
            subx    %r2, 6              ; r2 = static_data->reloc_tab_bot - 1 (ptr arith)
            stx     %r2, %r1            ; static_data->reloc_tab_bot -= 1
            ldx     %r0, %bp            ; r0 = static_data->asm_ip
            stx     %r0, %r2            ; reloc->asmp_ip = static_data->asm_ip
            addx    %r2, 2              ; point at &reloc.entry
            popx    %r0                 ; reload entry from stack
            stx     %r0, %r2            ; reloc->entry = entry
            addx    %r1, -4             ; offset of lineno from reloc_tab_bot ofs
            ldx     %r0, %r1            ; r0 = static_data->src_lineno
            addx    %r2, 2              ; point at &reloc.src_lineno
            stx     %r0, %r2            ; reloc->src_lineno = static_data->src_lineno
            mov     %r0, 0              ; prepare return value of 0
            jmp     fp_get_symbol_unwind2 ; unwind, but we've already popped off entry
fp_get_symbol_unwind:
            addx    %sp, 2              ; discard top of stack (spilled entry)
fp_get_symbol_unwind2:
            popx    %r2                 ; stack unwind
            popx    %ln
            ret

; sp_get_symbol
;   r0: table_entry entry
; returns
;   r0: payload from that entry
; No clobbers.
; This function crashes wiht an 'unknown symbol' error if the entry->payload
; is 0. This would happen if we called find_table_entry on the same symbol
; at some point, but then never attached a payload (found the defn site) later.
sp_get_symbol:
            stx     %r0, %sp            ; cache entry at top-of-stack without pushing
            addx    %r0, 8
            addx    %r0, 8              ; point at entry.payload
            ldx     %r0, %r0            ; r0 = entry->payload
            testx   %r0, -1             ; test payload
            retnz                       ; if it's nonzero, we're done
            ldx     %r1, %sp            ; otherwise, reload the entry
                                        ; which is also a pointer to &entry.symbol
            mov     %r0, 5              ; arg 0 = UNKNOWN_SYMBOL_CODE
            call    die                 ; crash

;;; The relocation table:
;;; The static data maintains the relocation table top and bottom. It grows down,
;;; starting from the top of low memory. Each entry contains fields needed to
;;; revisit an instruction that was missing a symbol later. This includes the source
;;; line number, to emit during an error message if the symbol can't be found the
;;; second time around. The layout is as follows:
;;;                   ┌──────────────┐
;;;     base+0x0000   │    asm_ip    │
;;;                   ├──────────────┤
;;;     base+0x0002   │  ste *entry  │
;;;                   ├──────────────┤
;;;     base+0x0004   │  src_lineno  │
;;;                   └──────────────┘


;;; ********************************* ASSEMBLERS ***********************************

; Placed here for jump range reasons, just a stub function to get out
; to 'die' with the right argument.
fp_die_out_range:
            mov     %r0, 3              ; OUT_OF_RANGE_CODE
            call    die

; fp_0
; Same ABI as other assembler functions.
; Handles instructions with no operands.
fp_0:
            cmph    %r2, 15             ; opc <=? 15
            ja      fp_0_encode_ret     ; if not, encode a return
            movh    %r0, 4              ; otherwise, enc_fst = 4
            sloh    %r0, 0              ; enc_fst <<= 5
            orh     %r0, %r2            ; enc_fst |= opc
            movh    %r1, 0              ; enc_snd = 0
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding   ; tail-call
fp_0_encode_ret:
            mov     %r0, 7              ; regL = 7
            andh    %r2, 15             ; opc &= 15
            jmp     fp_RJ               ; tail-call


; fp_RJ
; Handles register-indirect jump instructions
fp_RJ:
            movh    %r1, %r0            ; enc_snd = reg
            sloh    %r1, 0              ; enc_snd <<= 5
            orh     %r1, %r2            ; enc_snd |= opc
            movh    %r0, 5              ; enc_fst = 5
            sloh    %r0, 15             ; enc_fst = enc_fst << 5 | 15
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding   ; tail-call

; fp_call_L
; Handles labeled call instructions
fp_call_L:
            subx    %r0, %r1            ; disp = tgt - here
            mov     %r1, 2047           ; get 2047 for comparison
            cmpx    %r0, %r1            ; disp >? 2047
            jg      fp_die_out_range    ; if yes, die
            rsubx   %r1, -1             ; r1 = ~2047 = -2048
            cmpx    %r0, %r1            ; disp <? -2048
            jl      fp_die_out_range
            mov     %r3, %r0            ; save displacement in r3
            mov     %r1, 8              ; arg 1 = 8
            call    shr4                ; imm = (imm >> 4) & 0xFF
            mov     %r1, 4              ; arg 1 = 4
            call    shr4                ; imm = (imm >> 4) & 0xF
            addh    %r0, 8
            addh    %r0, 8              ; imm += 16
            mov     %r1, 5
            sloh    %r1, 0              ; r1 = 5 << 5
            orh     %r0, %r1            ; enc_fst = imm | (5 << 5)
            mov     %r1, %r3            ; put displacement back in arg 1
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding   ; tail-call

; fp_jump_L
; Handles labeled jump instructions
fp_jump_L:
            rsubx   %r1, %r0            ; disp = tgt - done
            mov     %r0, 255            ; get 255 for comparison
            cmpx    %r1, %r0            ; disp >? 255
            jg      fp_die_out_range    ; if yes, die
            rsubx   %r0, -1             ; r0 = ~255 = -256
            cmpx    %r1, %r0            ; disp <? -256
            jl      fp_die_out_range
            cmpx    %r1, 0              ; disp <? 0
            jge     fp_jump_L_skip_inc  ; if not, don't adjust the opcode
            addx    %r2, 8
            addx    %r2, 8              ; opc += 16
fp_jump_L_skip_inc:
            mov     %r0, 4              ; enc_fst = 4
            sloh    %r0, 0              ; enc_fst <<= 5
            orh     %r0, %r2            ; enc_fst |= opc
                                        ; enc_snd = disp is already in r1
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding   ; tail-call

fp_RR:
            addh    %r1, %r1            ; regR <<= 1
            addh    %r1, %r1            ; regR <<= 1
            sloh    %r0, 0              ; regL <<= 5
            orh     %r1, %r0            ; enc_snd = regL (<< 5) | regR (<< 2)
fp_RX_shared:
            addh    %r3, %r3            ; size_bits << 1
            addh    %r3, %r3            ; size_bits << 2
            addh    %r3, %r3            ; size_bits << 3
            addh    %r3, %r3            ; size_bits << 4
            movh    %r0, %r3            ; enc_fst = size_bits << 4
            orh     %r0, %r2            ; enc_fst |= opc
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding

fp_RI_stdcall:
            pushx   %ln
fp_RI:
            sloh    %r0, 0              ; regL <<= 5
            movz    %r7, 31
            andh    %r1, %r7            ; imm &= 31
            orh     %r1, %r0            ; enc_snd = regL (<< 5) | imm (& 31)
            addh    %r3, 4              ; size_bits += 4
            jmp     fp_RX_shared        ; tail-call to setup enc_fst and numbytes

; finalize_encoding
;   r0: first byte
;   r1: second byte
;   r2: number of bytes to advance the program counter by
;   r5: &static_data
;   top of stack: return address. For 'finalize_encoding_stdcall', this should be in r7.
; returns
;   r5: &static_data
; Does not clobber r3 or r4.
;
; This is the main workhorse of the assembler. It places the encoded
; (or partially encoded, if a label is unavailable) instruction in its place in
; user-program memory and bumps the program counter.
;
; **All complete paths through 'fpsm' return through this function**.
;
; Placed somewhat centrally for jump range.
finalize_encoding_stdcall:
            pushx   %ln
finalize_encoding:
            ldx     %r7, %bp            ; r7 = iloc = static_data->asm_ip
            addx    %r2, %r7            ; r2 = iloc + numbytes
            stx     %r2, %bp            ; static_data->asm_ip += numbytes
            sth     %r0, %r7            ; *iloc = first byte
            addx    %r7, 1              ; iloc + 1
            sth     %r1, %r7            ; *(iloc + 1) = second byte
            popx    %ln
            ret


; fp_R
; Handles instructions with one register operand.
fp_R:
            cmph    %r2, 12             ; opc == 12?
            jne     fp_R_push           ; if not, encode a push
            movh    %r1, 6              ; otherwise, encode a pop
            jmp     fp_RR               ; tail-call
fp_R_push:
            movh    %r1, %r0            ; regR = regL
            movh    %r0, 6              ; regL = 6
            jmp     fp_RR               ; tail-call

; fp_I
; Handles instructions with one immediate operand (push u5)
fp_I:
            movh    %r0, 6              ; regL = 6
            jmp     fp_RI               ; tail-call

fp_LM:
            testx   %r4, -1             ; test name
            jz      assemble_long_mov   ; if it's null, dispatch immediately (tail call)
            movh    %r2, %r0            ; r2 = reg
            movx    %r0, %r4            ; arg 0 = name
            call    fp_get_symbol       ; lookup the payload for name
                                        ; clobbers(r1, r3)
            testx   %r0, -1             ; test it
            jnz     fp_LM_have_imm      ; if it's valid, rearrange args and go
            movh    %r0, -1             ; otherwise, set up to defer
            movh    %r1, %r2            ; arg 1 = reg
            movx    %r2, 8              ; numbytes = 8
            jmp     finalize_encoding   ; tail-call
fp_LM_have_imm:
            movx    %r1, %r0            ; arg 1 = imm
            movh    %r0, %r2            ; arg 0 = reg
                                        ; tail fall-through to assemble_long_mov

; assemble_long_mov
;   r0: dst register
;   r1: immediate value
;   r5: &static_data
;   top of stack: return address (will be popped)
; returns
;   r5: &static_data
;
; Assemble a long move into the code segment. Returns (through finalize_encoding)
; to the address on top of the stack.
assemble_long_mov:
            pushx   %r0                 ; spill reg
            pushx   %r1                 ; spill immediate
            cmpx    %r1, 0              ; imm <? 0
            mov     %r1, 0              ; arg 1 = 0
            jge     alm_L1              ; if imm >= 0, don't adjust arg 1
            mov     %r1, 1              ; otherwise arg 1 = 1
alm_L1:
            mov     %r2, 9              ; opc = 9
            mov     %r3, 1              ; size_bits = 1
            call    fp_RI_stdcall       ; encode 'mov %dst, bool(imm < 0)'
            popx    %r0                 ; r0 = reload immediate
            popx    %r4                 ; r4 = reload reg (r4 is not clobbered by fp_RI)
            movz    %r1, 31             ; get 31
            andx    %r1, %r0            ; r1 = bottom = imm & 31
            pushx   %r1                 ; spill bottom
            mov     %r1, 10             ; arg 1 = 10
            call    shr5                ; middle = (imm >> 5) & 0x3FF
            movz    %r1, 31
            andx    %r1, %r0            ; r1 = middle & 0x1F
            pushx   %r1                 ; spill that value
            mov     %r1, 5              ; arg 1 = 5
            call    shr5                ; top = (imm >> 10) & 0x1F
            mov     %r1, %r0            ; arg 1 = top
            mov     %r0, %r4            ; arg 0 = reg
            mov     %r2, 12             ; arg 2 = 12
            mov     %r3, 1              ; size_bits = 1
            call    fp_RI_stdcall       ; encode 'slo %dst, ((imm >> 10) & 0x1F)'
            popx    %r1                 ; arg 1 = reload middle & 0x1F
            mov     %r0, %r4            ; arg 0 = reg
            mov     %r2, 12             ; arg 2 = 12
            mov     %r3, 1              ; size_bits = 1
            call    fp_RI_stdcall       ; encode 'slo %dst, ((imm >> 5) & 0x1F)'
            popx    %r1                 ; reload bottom
            mov     %r0, %r4            ; arg 0 = reg
            mov     %r2, 12             ; arg 2 = 12
            mov     %r3, 1              ; size_bits = 1
            jmp     fp_RI               ; encode 'slo %dst, (imm & 0x1F)' and return

; placement up here gets fpsm_reject in jump range for below
fp_LJ_good_payload:
            mov     %r1, 30             ; get 30 for comparison
            cmph    %r2, %r1            ; opc == 30?
            ldx     %r1, %bp            ; arg 1 = static_data->asm_ip
            je      fp_call_L           ; if opc == 30, go to call_L
            jmp     fp_jump_L           ; otherwise, to jump_L

; fp_LJ
; Handles labeled jump instructions
fp_LJ:
            cmph    %r2, 15             ; opc >? 15
            jbe     fp_LJ_good_opc      ; if no, we have a jump which is valid
            mov     %r0, 30             ; get 30 for comparison
            cmph    %r2, %r0            ; opc == 30?
            jne     fpsm_reject         ; if no, reject
                                        ; this branch is fairly tight, only ~15
                                        ; spare instructions of space
fp_LJ_good_opc:
            mov     %r0, %r4            ; arg 0 = name
            call    fp_get_symbol       ; r0 = payload for name in symtab
                                        ; clobbers(r1, r3)
            testx   %r0, -1             ; test the payload
            jnz     fp_LJ_good_payload  ; if it's not 0, dispatch to {call/jump}_L
            movh    %r0, %r2            ; arg 0 = opc
            mov     %r1, -1             ; arg 1 = -1
            mov     %r2, 2              ; numbytes = 2
            jmp     finalize_encoding   ; tail-call

;;; ********************************* STATE MACHINE ********************************

; fpsm
; Short for "first pass state machine"
;   r5: pointer to static_data
; returns
;   r5: pointer to static_data
;   static_data.save_cur is the last read character
; Clobbers everything except r5 :)

; design remarks:
;   this function always either crashes with an error or returns through finalize_encoding.
;   We put our return address on the stack and don't restore it; finalize_encoding
;   will do that if it gets there.
;   The different cases are implemented with a jump table.
;   The lexing functions all clobber at most r0 and r1, and update r5 coherently.
;   That gives us r2-r4 as allocated registers, as well as r7 as a volatile temp.

; register map:
;   r0: volatile
;   r1: volatile. Across loop iteration boundaries, holds current state.
;   r2: regL
;   r3: imm/regR (shared, see comments in the C code)
;   r4: symbolptr. Sometimes a reload slot for opcode when available.
;   r5: cur, after possibly reading label. &static_data before then.
;   r6: stack pointer
;   r7: volatile
; stack map (starting at 0xFFFE which may not be the real address!)
;   0xFFFE   |   return address   |
;   ---------|--------------------|
;   0xFFFC   |    &static_data    |
;   ---------|--------------------|
;   0xFFFA   |      size_bits     |
;   ---------|--------------------|
;   0xFFF8   |        opcode      |
;   ---------|--------------------|
fpsm:
            pushx   %ln
            pushx   %r5
            ldx     %r3, %r5            ; r3 = static_data->asm_ip
            ldh     %r5, STREAM         ; initialize reader
            call    cur_is_alpha        ; r0 = is_alpha(cur)
            testh   %r0, -1             ; test is_alpha(cur)
            jz      fpsm_0_notalpha     ; branch past name read if not name start
            call    read_name           ; r0 = pointer to read-in name
            movh    %r4, %r5            ; stash cur in r4
            popx    %r5                 ; temporarily reload &static_data
            movx    %r1, %r3            ; r1 = static_data->asm_ip
            call    ste_attach_payload  ; add this entry to the symbol table
            pushx   %r5                 ; re-push &static_data
            movh    %r5, %r4            ; restore cur to r5
            mov     %r0, ':'
            call    match               ; cur == ':'?
            testh   %r0, -1             ; test result
            jnz     fpsm_reject         ; reject with syntax error if cur != ':'
fpsm_0_notalpha:
            mov     %r1, 1              ; state = 1
            jmp     fpsm_iterate        ; step the loop

fpsm_1:                                 ; switch case 1
            call    cur_is_eol          ; r0 = is_eol(cur)
            testh   %r0, -1             ; test result
            jnz     fpsm_1_accept       ; accept if is_eol(cur)
            call    read_opcode         ; r0 = rop.opcode, r1 = rop.state
            movh    %r4, %r0            ; temporarily save the opcode in r4
            movh    %r3, %r1            ; temporarily save the target state in r3
            call    read_size           ; r0 = size_bits
            pushx   %r0                 ; put size_bits in their stack slot
            pushx   %r4                 ; put opcode into its stack slot
            movh    %r1, %r3            ; re-place the state in r1
            jmp     fpsm_iterate        ; break
fpsm_1_accept:
            popx    %r4                 ; restore static_data pointer
            addx    %r4, EOL_CHAR_OFS   ; &static_data.eol_char
            sth     %r5, %r4            ; static_data->eol_char = cur
            subx    %r4, EOL_CHAR_OFS   ; undo offset
            movx    %r5, %r4            ; move pointer back where it belongs
            popx    %ln
            ret

fpsm_2:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_2_imm          ; if not equal, try checking immediate
            call    read_register       ; if yes equal, read a register
            movh    %r2, %r0            ; regL = read_register()
            mov     %r1, 12             ; state = 12
            jmp     fpsm_iterate        ; break
fpsm_2_imm:
            call    cur_is_imm_start    ; r0 = is_imm_start(cur)
            testh   %r0, -1             ; test is_imm_start(cur)
            jz      fpsm_reject         ; if !is_imm_start(cur), this state rejects
            call    read_immediate      ; otherwise, read the immediate
            movz    %r1, 31             ; validate_u5 in %r0; see 'validate_u5' below
            cmpd    %r0, %r1            ; set 'be' condition if imm is valid
            ja      fpsm_invalid_imm    ; if not 'be' condition, imm is invalid. Die.
            movx    %r3, %r0            ; imm = read & validated immediate
            mov     %r1, 13             ; state = 13
            jmp     fpsm_iterate        ; break

fpsm_3:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_3_label        ; if not equal, try checking label
            call    read_register       ; if yes equal, read a register
            movh    %r2, %r0            ; regL = read_register()
            mov     %r1, 14             ; state = 14
            jmp     fpsm_iterate        ; break
fpsm_3_label:
            call    cur_is_alpha        ; r0 = is_alpha(cur)
            testh   %r0, -1             ; test is_alpha(cur)
            jz      fpsm_reject         ; if !is_alpha(cur), this state rejects
            call    read_name           ; r0 = read_name()
            movx    %r4, %r0            ; symbolptr = read_name()
            mov     %r1, 15             ; state = 15
            jmp     fpsm_iterate        ; break

fpsm_4:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_reject         ; if not a register, this state rejects
            call    read_register       ; r0 = read_register()
            movh    %r2, %r0            ; regL = read_register()
            mov     %r1, 12             ; state = 12
            jmp     fpsm_iterate        ; break

fpsm_5:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_reject         ; if not a register, this state rejects
            call    read_register       ; r0 = read_register()
            movh    %r2, %r0            ; regL = read_register()
            mov     %r1, 6              ; state = 6
fpsm_scan_comma:
            call    skip_whitespace     ; skip whitespace between reg and comma
            mov     %r0, ','            ; r0 = ',' to check
            call    match               ; r0 = (cur != ',')
            testh   %r0, -1             ; test (cur != ',')
            jnz     fpsm_reject         ; if it's not a comma, that's an error
            jmp     fpsm_iterate        ; break

fpsm_reject:
            mov     %r0, 0              ; r0 = INVALID_SYNTAX_CODE
            call    die
fpsm_invalid_imm:
            mov     %r0, 2              ; r0 = INVALID_IMMEDIATE_CODE
            call    die

fpsm_6:
            popx    %r4                 ; r4 = opc
            subx    %sp, 2              ; put %sp back so that opc stays on the stack
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_6_imm          ; if not a register, try checking immediate
            cmph    %r4, 12             ; opc == OPC_SLO?
            je      fpsm_reject         ; this state rejects OPC_SLO
            call    read_register       ; r0 = read_register()
            movh    %r3, %r0            ; regR = read_register()
            mov     %r1, 16             ; state = 16
            jmp     fpsm_iterate        ; break
fpsm_6_imm:
            call    cur_is_imm_start    ; r0 = is_imm_start(cur)
            test    %r0, -1             ; test is_imm_start(cur)
            jz      fpsm_reject         ; if !is_imm_start(cur), this state rejects
            call    read_immediate      ; r0 = read_immediate()
            cmph    %r4, 10             ; opc >= 10?
            jae     fpsm_6_u5           ; if yes, validate unsigned
            cmph    %r4, 8              ; opc == 8?
            je      fpsm_6_u5           ; if yes, validate unsigned
fpsm_6_s5:
            call    validate_s5         ; r0 unchanged, flags set 'b' if valid
            jae     fpsm_invalid_imm    ; if not 'b' condition, imm is invalid. Die.
            jmp     fpsm_6_end          ; clean up
fpsm_6_u5:
            movz    %r1, 31             ; validate_u5 in %r0; see 'validate_u5' below
            cmpd    %r0, %r1            ; set 'be' condition if imm is valid
            ja      fpsm_invalid_imm    ; if not 'be' condition, imm is invalid. Die.
fpsm_6_end:
            movx    %r3, %r0            ; imm = r0
            mov     %r1, 17             ; state = 17
            jmp     fpsm_iterate        ; break

    ; this is placed somewhat centrally to maximize the coverage of its jump range.
    ; The only jump _out_ is via a register, but several places need to jump _in_.
fpsm_iterate:
            call    skip_whitespace
            cmph    %r1, 10             ; compare state to 10
            ja      fpsm_eol            ; if bigger, go to the eol+accept check
            call    fpsm_iterate_2      ; put the address of the action table in r7
fpsm_action_table:
            .word   fpsm_reject fpsm_1 fpsm_2 fpsm_3 fpsm_4
            .word   fpsm_5 fpsm_6 fpsm_7 fpsm_8 fpsm_9
fpsm_iterate_2:
            addh    %r1, %r1            ; state *= sizeof(word)
            addx    %r1, %r7            ; r1 = pointer to pointer switch case
            ldx     %r1, %r1            ; r1 = pointer to switch case
            jmp     %r1                 ; follow the yellow brick road

fpsm_7:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_reject         ; if not register, this state rejects
            call    read_any_register   ; r0 = read_any_register()
            movh    %r2, %r0            ; regL = read_any_register()
            cmph    %r2, 8              ; regL <? 8
            mov     %r1, 8              ; state = 8
            jb      fpsm_scan_comma     ; if regL < 8, scan comma
            mov     %r1, 9              ; otherwise, state = 9
            jmp     fpsm_scan_comma     ; then scan comma

fpsm_8:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; cur == '%'?
            jne     fpsm_8_imm          ; if not register, try immediate
            call    read_any_register   ; r0 = read_any_register()
            movh    %r3, %r0            ; regR = read_any_register()
            cmph    %r3, 8              ; regR <? 8
            jge     fpsm_8_ctrl_reg     ; if regR >= 8, it's a control reg
            mov     %r1, 16             ; state = 16
            jmp     fpsm_iterate        ; break
fpsm_8_ctrl_reg:
            subh    %r3, 8              ; imm = regR - 8
            addx    %sp, 2              ; point at stack slot of opc
            pushx   14                  ; overwrite opc with 14
            mov     %r1, 17             ; state = 17
            jmp     fpsm_iterate        ; break
fpsm_8_imm:
            call    cur_is_imm_start    ; r0 = is_imm_start(cur)
            testh   %r0, -1             ; test is_imm_start(cur)
            jz      fpsm_8_label        ; if not an imm, try label
            call    read_immediate      ; r0 = read_immediate()
            call    validate_s5         ; set 'b' if r0 is a valid s5
            mov     %r1, 17             ; state = 17
            movd    %r3, %r0            ; imm = read_immediate()
            jb      fpsm_iterate        ; break, if imm is a valid s5
            movsx   %r0, %r3            ; r0 = sign_extend(imm, 16)
            cmpd    %r0, %r3            ; imm == sign_extend(imm, 16)?
            je      fpsm_8_vld_i16      ; if yes, it's valid
            movzx   %r0, %r3            ; otherwise try r0 = zero_extend(imm,16)
            cmpd    %r0, %r3            ; imm == zero_extend(imm, 16)?
            jne     fpsm_invalid_imm    ; if no, imm is not a valid i16. Die.
fpsm_8_vld_i16:
            mov     %r4, 0              ; symbolptr = NULL
            mov     %r1, 18             ; state = 18
            jmp     fpsm_iterate        ; break
fpsm_8_label:
            call    cur_is_alpha        ; r0 = is_alpha(cur)
            testh   %r0, -1             ; test is_alpha(cur)
            jz      fpsm_reject         ; if !is_alpha(cur), finally this state rejects.
            call    read_name           ; r0 = read_name()
            movx    %r4, %r0            ; symbolptr = read_name()
            mov     %r1, 18             ; state = 18
            jmp     fpsm_iterate        ; break

fpsm_9:
            mov     %r0, '%'            ; r0 = '%' to check for register
            cmph    %r5, %r0            ; r0 == '%'?
            jne     fpsm_reject         ; if not a register, this state rejects
            movh    %r3, %r2            ; imm = regL
            subh    %r3, 8              ; imm -= 8
            call    read_register       ; r0 = read_register()
            movh    %r2, %r0            ; r2 = read_register()
            addx    %sp, 2              ; point %sp at stack slot of opc
            pushx   15                  ; overwrite opc with 15
            mov     %r1, 17             ; state = 17
            jmp     fpsm_iterate

fpsm_eol:
            call    cur_is_eol          ; r0 = is_eol(cur)
            testh   %r0, -1             ; test is_eol(cur)
            jz      fpsm_reject         ; if it's not eol (somehow?) reject!
fpsm_accept:
            addx    %sp, 6              ; point at stack slot of &static_data
            ldx     %r7, %sp            ; r7 = &static_data
            subx    %sp, 6              ; restore %sp
            addx    %r7, EOL_CHAR_OFS   ; r7 = &static_data.eol_char
            sth     %r5, %r7            ; static_data->eol_char = cur
            movh    %r5, %r1            ; r5 = state, temporarily
            movh    %r0, %r2            ; arg 0 = regL
            movx    %r1, %r3            ; arg 1 = regR/imm
            popx    %r2                 ; arg 2 = opcode
            popx    %r3                 ; arg 3 = size_bits
                                        ; arg 4 is already symbolptr
            call    fpsm_accept_exit    ; get the address of the table into r7
fpsm_accept_jump_table:
            .word   fp_0 fp_R fp_I fp_RJ fp_LJ fp_RR fp_RI fp_LM
fpsm_accept_exit:
            subh    %r5, 11             ; offset = state - 11
            addh    %r5, %r5            ; offset *= sizeof(word)
            addx    %r7, %r5            ; r7 = pointer to address to jump to
            ldx     %r7, %r7            ; r7 = address to jump to
            popx    %r5                 ; r5 = &static_data. Hooray!
            jmp     %r7                 ; tail-call the assembling function
                                        ; with its return address on top-of-stack.


;;; ********************************************************************************
;;; ************************************ LEXER *************************************
;;; ********************************************************************************

; skip_whitespace
;   r5: cur
; returns
;   r5: cur
; Clobbers r0.
skip_whitespace:
            mov     %r0, ' '            ; r0 = 32
            jmp     skip_whitespace_L2
skip_whitespace_L1:
            ldh     %r5, STREAM         ; cur = getchar()
skip_whitespace_L2:
            cmph    %r5, %r0            ; r5 ==? 32
            je      skip_whitespace_L1
            cmph    %r5, '\t'           ; r5 ==? 9
            je      skip_whitespace_L1

            mov     %r0, ';'            ; r0 = 59
            cmph    %r5, %r0
            retne                       ; return if cur != ';'
            pushx   %ln
skip_whitespace_L3:
            ldh     %r5, STREAM         ; cur = getchar()
            call    cur_is_eol          ; r0 = is_eol(cur)
            testh   %r0, -1             ; test is_eol(cur)
            jz      skip_whitespace_L3  ; loop as long as is_eol(cur) is false
            popx    %ln
            ret

; read_size
;   r5: cur
; returns
;   r0: size_bits for the previously lexed opcode
;   r5: cur
; Clobbers r1.
;
; Crashes with "invalid syntax" if a valid size_suffix? cannot be read.
read_size:
            pushx   %ln
            call    cur_is_alpha        ; r0 = is_alpha(cur)
            testh   %r0, -1             ; test is_alpha(cur)
            mov     %r0, 1              ; set return value for if !is_alpha(cur)
            jz      read_size_ret
            mov     %r1, 'x'            ; r1 = 120
            subh    %r5, %r1            ; cur = cur - 'x'
            je      read_size_guard
            subh    %r5, -16            ; cur = cur + ('x' - 'h')
            mov     %r0, 0              ; set return value for cur == 'h'
            je      read_size_guard
            addh    %r5, 4              ; cur = cur + ('h' - 'd')
            mov     %r0, 2              ; set return value for cur == 'd'
            jne     read_size_kill      ; not valid suffix if cur != 'd' at this point
read_size_guard:
            pushx   %r0                 ; spill return value
            ldh     %r5, STREAM         ; cur = getchar()
            call    cur_is_alphanum     ; r0 = is_alphanum(cur)
            testh   %r0, -1             ; test is_alphanum(cur)
            jnz     read_size_kill      ; crash if cur is alphanumeric
            popx    %r0                 ; reload return value
read_size_ret:
            popx    %ln
            ret
read_size_kill:
            mov     %r0, 0              ; r0 = INVALID_SYNTAX_CODE
            call    die


; read_immediate
;   r5: cur
; returns
;   r0: int32_t the read immediate
;   r5: cur
; Additionally clobbers r1.
;
; Reads an immediate value from the input stream. Cur must initially be the
; first character of the token, either a number or '-'. Cur will be the first
; unused character afterwards.
read_immediate:
            pushx   %r2                 ; wind
            mov     %r0, '-'            ; 45, this mov is 2 instructions
            mov     %r1, '0'            ; this mov is also 2 instructions
            rsubh   %r0, %r5            ; r0 = r5 - 45
            pushx   %r0                 ; save the result of this subtraction
            je      read_immediate_L2   ; read extra char if '-'; r0 = imm = 0 since 'e'
            mov     %r0, 0              ; r0 = imm = 0
            jmp     read_immediate_L3   ; jump to loop add step
read_immediate_L1:
            addd    %r0, %r0            ; imm *= 2
            movd    %r2, %r0            ; immx2 = imm
            addd    %r0, %r0            ; imm *= 2 (x4 cumulative)
            addd    %r0, %r0            ; imm *= 2 (x8 cumulative)
            addd    %r0, %r2            ; imm = imm + immx2 (x10 cumulative)
            addd    %r0, %r5            ; imm = imm + cur - 48
read_immediate_L2:
            ldh     %r5, STREAM         ; r5 = getchar()
read_immediate_L3:
            subh    %r5, %r1            ; r5 = cur - 48
            cmph    %r5, 10             ; compare (cur - 48) to 10
            jb      read_immediate_L1   ; loop if 0 <= (cur - 48) < 10

            addh    %r5, %r1            ; r5 = cur (previously, r5 = cur-48)
            popx    %r1                 ; retrieve the comparison of initial cur to '-'
            popx    %r2                 ; unwind stack
            testh   %r1, -1             ; test the result of that comparison, zero means equal
            retnz                       ; if it wasn't equal, we're done
            rsubd   %r0, 0              ; otherwise, imm = -imm
            ret                         ; and now we're done.

; read_name
;   r5: cur, which must satisfy is_alpha.
; returns
;   r0: pointer to read name. The string is nul-terminated iff it is less than 16 characters.
;       The returned string *must* be copied if you want it to stick around through lexing
;       another token. Any lexer function may use the buffer.
;   r5: new cur
; Clobbers only r1. Other registers are preserved.
;
; At most 16 characters are read. If 16 characters are read, the string will not be
; nul-terminated. This means it is not safe to print the result.
read_name:
            pushx   %ln
            pushx   %r2
            mov     %r0, 32             ; r0 = buffer
            mov     %r2, 0              ; i = 0
read_name_L1:
            sth     %r5, %r0            ; *buffer = cur
            addx    %r0, 1              ; ++buffer
            addh    %r2, 1              ; ++i
            ldh     %r5, STREAM         ; cur = getchar()
            cmph    %r2, 15             ; i <=? 15
            ja      read_name_L3        ; return if i > 15
            pushx   %r0                 ; spill buffer
            call    cur_is_name_char    ; r0 = is cur a valid name char?
            test    %r0, 1
            popx    %r0                 ; unspill buffer
            jnz     read_name_L1        ; if it's valid, loop
read_name_L2:                           ; if we reach this label, i < 16
            mov     %r1, 0
            sth     %r1, %r0            ; *buffer = 0
read_name_L3:
            subx    %r0, %r2            ; buffer = buffer - i === 32
            popx    %r2
            popx    %ln
            ret

; read_any_register
;   r5: cur, which should be '%'
; returns
;   r0: unsigned byte index of the register. >=8 means control register.
;       See the C code for the mapping.
;   r5: new cur
; Clobbers r1.
;
; This function can fairly easily be moved away from space-critical sections
; if needed, by leaving the lookup table and a call stub somewhere accessible
; and calling the body of the function further away. However, it needs access
; to strncmp, consume, and is_alphanum.
read_any_register:
            pushx   %ln
            call    read_any_register_actual ; put &register_table in %ln
register_table:
            ; we order this table to give priority to the register names that
            ; are used most often by object programs. I'm just guessing at the
            ; moment that this will favor S&F register names.
            .ascii  "a0"
            .word   0 empty_str
            .ascii  "a1"
            .word   1 empty_str
            .ascii  "a2"
            .word   2 empty_str
            .ascii  "s0"
            .word   3 empty_str
            .ascii  "s1"
            .word   4 empty_str
            .ascii  "bp"
            .word   5 empty_str
            .ascii  "sp"
            .word   6 empty_str
            .ascii  "ln"
            .word   7 empty_str
            .ascii  "r0"
            .word   0 empty_str
            .ascii  "r1"
            .word   1 empty_str
            .ascii  "r2"
            .word   2 empty_str
            .ascii  "r3"
            .word   3 empty_str
            .ascii  "r4"
            .word   4 empty_str
            .ascii  "r5"
            .word   5 empty_str
            .ascii  "r6"
            .word   6 empty_str
            .ascii  "r7"
            .word   7 empty_str
            .ascii  "cp"
            .word   8 uid_str
            .ascii  "ex"
            .word   9 ten_str
            .ascii  "fe"
            .word   10 at_str
read_any_register_actual:
            pushx   %r2
            pushx   %r3
            pushx   %r4                 ; wind the stack (%ln already pushed)
            mov     %r3, 32             ; r3 = buffer
            ldh     %r0, STREAM
            sth     %r0, %r3            ; *buffer = getchar()
            addx    %r3, 1
            ldh     %r0, STREAM
            sth     %r0, %r3            ; *(buffer + 1) = getchar()
            subx    %r3, 1              ; r3 = buffer, once again
            movz    %r5, 18             ; i = 18
            movx    %r4, %r7            ; r7 previously held &register_table
read_any_register_L1:
            movx    %r0, %r3            ; arg0 = buffer
            movx    %r1, %r4            ; arg1 = register_table[18-i].name
            movx    %r2, 2              ; arg2 = 2
            call    strncmp             ; r0 = 0 iff string at buffer == string at name
            testh   %r0, -1             ; is r0 == 0?
            jz      read_any_register_L3; found match! break out of loop
            addx    %r4, 6              ; point r4 at next register table entry
            subh    %r5, 1              ; --i
            jge     read_any_register_L1; loop as long as i is still >= 0
read_any_register_L2:                   ; but if i < 0, there were no matches. Die.
            mov     %r0, 1              ; r0 = INVALID_REGISTER_CODE
            call    die
read_any_register_L3:
            ldh     %r5, STREAM         ; cur = getchar() [in the C code, this is above the loop]
            addx    %r4, 4              ; point r4 at entry.remainder_to_consume
            ldx     %r1, %r4            ; r1 = entry->remainder_to_consume
            call    consume             ; r0 = 0 iff consume succeeds
            testh   %r0, -1             ; is r0 == 0?
            jnz     read_any_register_L2; call die(INVALID_REGISTER) if consume failed
            call    cur_is_alphanum     ; r0 = is_alphanum(cur)
            testh   %r0, -1             ; is r0 != 0?
            jnz     read_any_register_L2; call die(INVALID_REGISTER) if is_alphanum(cur)
            subx    %r4, 2              ; point r4 at entry.number
            ldx     %r0, %r4            ; return = entry->number
            popx    %r4
            popx    %r3
            popx    %r2                 ; unwind
            popx    %ln                 ; restore return address
            ret

; read_register, read_ctrl_register
;
; Same as 'read_any_register', but crashes if it reads a {/non}control register.
read_register:
            pushx   %ln
            call    read_any_register
            popx    %ln
            cmph    %r0, 8
            retl                        ; return reg if it's < 8
            jmp     read_any_register_L2; otherwise, call die(INVALID_REGISTER)
read_ctrl_register:
            pushx   %ln
            call    read_any_register
            popx    %ln
            cmph    %r0, 8
            retge                       ; return reg if it's >= 8
            jmp     read_any_register_L2; otherwise, call die as above

; consume
;   r1: pointer to C string to match against STREAM
;   r5: cur
; returns
;   r0: 0 iff the init of {cur,*STREAM} matches *r0
;   r5: new cur
; Clobbers r1
consume_L1:
            ; INLINE CALL TO match
            rsubh   %r0, %r5            ; r0 = *check - cur
            ldh     %r5, STREAM         ; cur = getchar()
            ; END INLINE CALL
            retnz                       ; if match failed, return result
            addx    %r1, 1              ; ++check
consume:
            ldh     %r0, %r1            ; r0 = *check
            testh   %r0, -1             ; *check == 0?
            jnz     consume_L1          ; loop if *check != 0
            ret                         ; otherwise, return *check === 0

; match
;   r0: character
;   r5: cur
; returns
;   r0: cur - c === 0 iff cur == c
;   r5: new cur
;   flags: set according to cur - c
; No clobbers.
match:
    rsubh   %r0, %r5                    ; r0 = cur - c
    ldh     %r5, STREAM                 ; cur = getchar()
    ret


; read_opcode
;   r5: cur
; returns
;   r0: opcode
;   r1: State to transition the parsing state machine to
;   r5: cur
; Nothing else is clobbered.
read_opcode:
            pushx   %ln
            pushx   %r2
            pushx   %r3
            pushx   %r4
    ; register map for this function:
    ; r0   |   r.opcode, or buffer
    ; r1   |   r.state   or table[ix].name
    ; r2   |   volatile temporary
    ; r3   |   size
    ; r4   |   count     or trigger
    ; r5   |   table pointer, cur when necessary
            mov     %r0, 0              ; r.opcode = 0
            mov     %r1, 3              ; r.state = STATE_TX
            mov     %r2, 32             ; r2 = buffer
            sth     %r5, %r2            ; *buffer = cur
            movh    %r3, %r5            ; temporarily stash cur in r3
            ldh     %r5, STREAM         ; cur = getchar()
            addx    %r2, 1              ; ++buffer
            sth     %r5, %r2            ; *buffer = cur
            mov     %r4, 'j'            ; r4 = 'j' === 104
            cmph    %r3, %r4            ; check if original cur was 'j'
            mov     %r4, 0              ; trigger = HIT_J === 0
            je      read_opcode_cond    ; jump to the cond part if so
            mov     %r3, 2              ; size = 2
            mov     %r4, 2              ; count = 2
            mov     %r5, opcode_tables  ; r5 = pointer to opcode tables
                                        ; specifically, to table2[0].name
read_opcode_sloop:
            mov     %r0, 32             ; arg 0 = buffer
            mov     %r1, %r5            ; arg 1 = &table{2/3}[ix].name
            mov     %r2, %r3            ; arg 2 = size
            call    strncmp             ; r0 = (0 iff hit table)
            testh   %r0, -1             ; test for hit
            jnz     read_opcode_sstep   ; if not a hit, go to next step
            subx    %r5, 1              ; r5 = &table{2/3}[ix].opcode
            ldh     %r0, %r5            ; r.opcode = table{2/3}[ix].opcode
            mov     %r1, 5              ; r.state = STATE_COMP
            ldh     %r5, STREAM         ; cur = getchar()
            jmp     read_opcode_unwind  ; return
read_opcode_sstep:
            addx    %r5, %r3            ; tableptr += size
            addx    %r5, 1              ; tableptr += 1 [shift past next opcode]
            subh    %r4, 1              ; --count
            jge     read_opcode_sloop   ; loop if count still >= 0
            cmph    %r3, 2              ; check if size was 2 on that iteration
            mov     %r4, 4              ; count = 4, size is "still" 3 (it's from the future)
            jne     read_opcode_big     ; if not, stop the short loop
            mov     %r3, 3              ; size = 3
            mov     %r4, 5              ; count = 5
            mov     %r0, 34             ; r0 = buffer + 2
            ldh     %r2, STREAM         ; r2 = getchar()
            sth     %r2, %r0            ; *(buffer + 2) = r2
            jmp     read_opcode_sloop   ; continue checking short opcodes

read_opcode_bstep:
            addx    %r5, %r3            ; tableptr += size
            addx    %r5, 3              ; tableptr += 3 [shift past opcode,state,trigger]
            subh    %r4, 1              ; --count
            jge     read_opcode_bloop   ; loop now, if count still >= 0
            popx    %r2                 ; reload spilled cur into %r2
            cmph    %r3, 3              ; was size still 3 on that iteration?
            jne     read_opcode_die     ; if not, we're out of things to check. Die.
                                        ; If yes, fallthrough and try size 4.
read_opcode_try4:
            ; at this point, cur is in r2. The pointer might not be in r5.
            mov     %r0, 35             ; r0 = buffer + 3
            sth     %r2, %r0            ; *(buffer + 3) = cur
            mov     %r3, 4              ; size = 4
            mov     %r4, 5              ; count = 5
            mov     %r5, opcode_table4_state
                                        ; fallthrough to top of loop from here
read_opcode_big:                        ; before jumping here, count was set to {4/5}
            ldh     %r2, STREAM         ; get another character...
            pushx   %r2                 ; and spill it, because we still need the table
            addx    %r5, 2              ; was pointed at state, move it to name
read_opcode_bloop:
            mov     %r0, 32             ; arg 0 = buffer
            mov     %r1, %r5            ; arg 1 = &table{3/4}[ix].name
            mov     %r2, %r3            ; arg 2 = size
            call    strncmp             ; r0 = (0 iff hit table)
            testh   %r0, -1             ; test for hit
            jnz     read_opcode_bstep   ; if no hit, go to next iteration
            popx    %r2                 ; retrieve cur, which we spilled
            subx    %r5, 1              ; move pointer to trigger
            ldh     %r4, %r5            ; trigger = table[ix].trigger
            cmph    %r4, 2              ; trigger == HIT_MOV?
            jne     read_opcode_chkcond ; if it's not, try checking if it's HIT_COND
            movh    %r0, %r2            ; but if it is, check cur (which we reloaded to r2)
            call    is_not_opcode_suffix
            testh   %r0, -1             ; test !is_opcode_suffix(cur)
            jnz     read_opcode_try4    ; if holds, skip to trying length-4 names
read_opcode_chkcond:
            subx    %r5, 2              ; move pointer from trigger to opcode
            ldh     %r0, %r5            ; r.opcode = table[ix].opcode
            addx    %r5, 1              ; move pointer from opcode to state
            ldh     %r1, %r5            ; r.state  = table[ix].state
            movh    %r5, %r2            ; restore cur to r5 from r2 (where it was reloaded)
            cmph    %r4, 1              ; trigger == HIT_COND?
            jne     read_opcode_unwind  ; if no, go to stack unwind and return
read_opcode_cond:
                                        ; otherwise, we are in the cond section
            ; no matter how we get here, we have the following invariants:
            ; r0 has our opcode
            ; r1 has the target state
            ; r4 has the trigger
            ; r5 has cur
            pushx   %r1                 ; spill r.state
            pushx   %r0                 ; spill r.opcode
            mov     %r2, 2              ; i = 2
            mov     %r3, 32             ; r3 = buffer
read_opcode_bfrcond:
            call    cur_is_not_opcode_suffix
            testh   %r0, -1             ; test !is_opcode_suffix(cur)
            jz      read_opcode_condtbl ; if it doesn't hold (cur is an opcode suffix)
                                        ;   then we can start checking the table
            sth     %r5, %r3            ; *buffer = cur
            ldh     %r5, STREAM         ; cur = getchar()
            addx    %r3, 1              ; ++buffer
            subh    %r2, 1              ; --i
            jg      read_opcode_bfrcond ; continue buffering if i > 0
read_opcode_condtbl:
            mov     %r2, 0              ; clear r2
            sth     %r2, %r3            ; *buffer = 0
            mov     %r3, cond_table_name ; get pointer to cond_table[0].name in r3
            mov     %r2, %r4            ; r2 = trigger
            addh    %r2, %r2            ; r2 = trigger * 2
            addh    %r2, %r2            ; r2 = trigger * 4
            addx    %r3, %r2            ; r3 = cond_table[trigger].name
            movz    %r2, 20
            rsubh   %r4, %r2            ; trigger = 20 - trigger
read_opcode_cndloop:
            mov     %r0, 32             ; arg 0 = buffer
            movx    %r1, %r3            ; arg 1 = cond_table[ix].name
            mov     %r2, 3              ; arg 2 = 3
            call    strncmp             ; r0 = (0 iff hit table)
            testh   %r0, -1             ; test if hit
            jz      read_opcode_hitcond ; if we hit, go leave (finally)
            addx    %r3, 4              ; otherwise, move to next cond table entry
            subh    %r4, 1              ; --trigger
            jg      read_opcode_cndloop ; continue looping if trigger > 0
read_opcode_die:
            mov     %r0, 0
            call    die                 ; otherwise, we are out of options. Die.
read_opcode_hitcond:
            popx    %r0                 ; reload r.opcode
            popx    %r1                 ; reload r.state
            subx    %r3, 1              ; move back from name to opcode
            ldh     %r3, %r3            ; read in the opcode
            addh    %r0, %r3            ; r.opcode += cond_table[hit].opcode
read_opcode_unwind:
            popx    %r4
            popx    %r3
            popx    %r2
            popx    %ln
            ret


; validate_u5
; rather than calling this function, you should inline the following defn:
;           movz    %temp, 31
;           cmpd    %r0, %temp
; This sets the 'be' condition if the input int32_t is a valid u5, and unsets
; it otherwise.
; Each call to this function would take 1 instruction, and the function itself
; would be 3. So unless the function needs to be inlined more than twice, inlining
; it will be better (note: at the time of writing, it has 2 callsites).

; validate_s5
; This one is worth implementing as a function as it is larger and has 2 callsites.
;   r0: int32_t to check
; returns
;   r0: the same int32_t
;   flags: sets the 'b' condition if the immediate is valid, and unsets it otherwise.
;       Note that this is different from the validate_u5 code, which sets 'be'!
; data in registers is unchanged. Remember that when we say this, we only
; guarantee 16 bit data is preserved. The only 32 bit data we handle is unvalidated
; immediates, so that should be fine!
validate_s5:
            pushx   %r0
            pushx   %r1
            movz    %r1, 16
            addd    %r0, %r1            ; imm + 16
            addx    %r1, %r1            ; r1 = 32
            cmpd    %r0, %r1            ; compare (imm + 16) against 32
            popx    %r1                 ; if 0 <= (imm + 16) < 32, then imm
            popx    %r0                 ; is a valid s5 immediate. The compare
            ret                         ; will set the 'b' condition if so.

; validate_i16
;   r0: int32_t to check
; returns
;   flags: sets the 'z' condition if the immediate is valid, and unsets it otherwise.
; data in registers is unchanged.
;
; The definition to inline is:
;           movsx   %temp, %r0          ; temp = sign_extend(r0, 16)
;           cmpd    %r0, %temp          ; r0 =? sign_extend(r0, 16)

;;; ********************************************************************************
;;; ******************************** AD-HOC CTYPE.H ********************************
;;; ********************************************************************************

; is_alpha
;   r0: character
; returns
;   r0: boolean: is that character alphabetic?
; Clobbers r1.
cur_is_alpha:
            mov     %r0, %r5
is_alpha:
            mov     %r1, 65             ; r1 = 'A'
            cmph    %r0, %r1
            jb      is_alpha_ret_false  ; return false if r0 < 'A'
            addh    %r1, 15
            addh    %r1, 10             ; r1 = 'Z'
            cmph    %r0, %r1            ; c <=? 'Z'
            jbe     is_alpha_ret_true
            addh    %r1, 5              ; r1 = '_'
            cmph    %r0, %r1            ; c ==? '_'
            je      is_alpha_ret_true
            addh    %r1, 2              ; r1 = 'a'
            cmph    %r0, %r1            ; c <? 'a'
            jb      is_alpha_ret_false
            addh    %r1, 15
            addh    %r1, 10             ; r1 = 'z'
            cmph    %r0, %r1            ; c <=? 'z'
            jbe     is_alpha_ret_true   ; fall through to ret_true otherwise
is_eol_ret_false:
is_num_ret_false:
is_alpha_ret_false:
            mov     %r0, 0
            ret
is_eol_ret_true:
is_num_ret_true:
is_alpha_ret_true:
is_imm_start_ret_true:
            mov     %r0, 1
            ret

; is_imm_start
;   r0: character
; returns
;   r0: boolean: is that character numeric or '-'?
; Clobbers r1.
;
; is_num
;   r0: character
; returns
;   r0: boolean: is that character numeric?
;   r1: constant 48
; Clobbers r1.
;
; is_num_have_48
; Same as is_num, but is a shortcut entrypoint if %r1 already contains exactly 48.
cur_is_imm_start:
            mov     %r0, %r5
is_imm_start:
            mov     %r1, '-'
            cmph    %r0, %r1            ; c ==? '-'
            je      is_imm_start_ret_true
            addh    %r1, 3              ; r1 = '0'
            jmp     is_num_have_48      ; this entrypoint is less common

cur_is_num:
            mov     %r0, %r5
is_num:
            mov     %r1, '0'
is_num_have_48:
            subh    %r0, %r1            ; c = c - '0'
            cmph    %r0, 10             ; c <? '9'+1
            jb      is_num_ret_true
            jmp     is_num_ret_false

; is_alphanum
;   r0: character
; returns
;   r0: boolean: is that character alphabetic, a number, or '_'?
; Clobbers r1.
;
; is_name_char
; Equivalent to is_alphanum. Historical in the C code, I guess.
cur_is_alphanum:
cur_is_name_char:
            mov     %r0, %r5
is_alphanum:
is_name_char:
            pushx   %ln                 ; we call functions, save %ln
            pushx   %r0                 ; save c
            call    is_alpha            ; r0 = is_alpha(c)
            testh   %r0, 1              ; test is_alpha(c)
            popx    %r1                 ; r1 = c
            jnz     is_name_char_ret    ; return if is_alpha(c)
            movh    %r0, %r1            ; r0 = c
            call    is_num              ; r0 = is_num(c)
is_name_char_ret:
            popx    %ln
            ret

; is_eol
;   r0: character
; returns
;   r0: boolean: is that character either 10 or 0?
; Clobbers nothing.
cur_is_eol:
            mov     %r0, %r5
is_eol:
            cmph    %r0, 10             ; c ==? '\n'
            je      is_eol_ret_true
            cmph    %r0, 0              ; c ==? '\0'
            je      is_eol_ret_true
            jmp     is_eol_ret_false

; is_not_opcode_suffix
;   r0: character
; returns
;   r0: boolean: is that character NOT valid to appear after an opcode?
; Clobbers r1.
cur_is_not_opcode_suffix:
            mov     %r0, %r5
is_not_opcode_suffix:
            mov     %r1, %r0            ; swap registers
            mov     %r0, 'x'            ; r0 = 'x' = 120
            rsubh   %r0, %r1            ; r0 = c - 'x'
            retz                        ; if 0, c == 'x' which is valid, return 0
            subh    %r0, -16            ; r0 = (c - 'x') - ('h' - 'x') === c - 'h'
            retz                        ; same, but == 'h'
            addh    %r0, 4              ; r0 = (c - 'h') + ('h' - 'd') === c - 'd'
            retz                        ; same, but == 'd'
            mov     %r0, %r1            ; r0 = c
            jmp     is_alpha            ; tail-call is_alpha. Our return sense is inverted,
                                        ; so if is alpha returns yes, we return no. Perf!


;;; ********************************************************************************
;;; ******************************* SYSTEM UTILITIES *******************************
;;; ********************************************************************************

; die
;   r0: code indicating which message we should print
;       0: invalid syntax
;       1: invalid register
;       2: invalid immediate
;       3: out of range
;       4: out of memory
;       5: unknown symbol
;   r2: a symbol, if code is 5.    NOTE THIS IS R2
; returns
;   none; program execution will end.
;
; Due to the wide range of places where this function is used, it does not
; assume that a pointer to static_data is available.
die:
            call    die_actual          ; %r7 = &msg_header
msg_header:                             ; char **msg_header
            .word   invalid_msg
            .word   invalid_msg
            .word   invalid_msg
            .word   out_of_msg
            .word   out_of_msg
            .word   empty_msg
msg_body:                               ; char **msg_body
            .word   syntax_msg
            .word   register_msg
            .word   immediate_msg
            .word   range_msg
            .word   memory_msg
            .word   unknown_symbol_msg
die_actual:
            movx    %r2, %r1            ; save name in r2 which is stable (r1 is not)
            movx    %r5, %r7            ; save &msg_header
            addh    %r0, %r0            ; ofs = code << 1
            addx    %r0, %r7            ; r0 = &(msg_header[code])
            movx    %r3, %r0            ; save &(msg_header[code]) for later
            ldx     %r0, %r0            ; r0 = msg_header[code]
            call    puts                ; puts(msg_header[code])
            movx    %r0, %r3            ; retrieve &msg_header[code]
            addx    %r0, 12             ; r0 = &msg_body[code]
            ldx     %r0, %r0            ; r0 = msg_body[code]
            call    puts                ; puts(msg_body[code])   additionally r1 = 0
            subx    %r3, %r5            ; r3 = &msg_header[code] - msg_header, eqv. 2*code
            cmpx    %r3, 10             ; compare 2*code against 10
            jne     die_line            ; if 2*code != 10, we're done and can print line and halt
            movx    %r0, %r2            ; move name to argument 0 (it was saved in r2 and is untouched)
            movz    %r2, 16             ; r2 = 16
            addx    %r2, %r0            ; r2 = &(name + 16)
            sth     %r1, %r2            ; *(name + 16) = 0,  r1 is still 0 since call to puts
            call    puts                ; puts(name)
die_line:
            call    die_line_with_msg
            .asciiz " at line "
            .align  2
die_line_with_msg:
            mov     %r0, %ln
            call    puts                ; print " at line "
            mov     %r0, BUFFER_PTR     ; arg 0 = buf
            mov     %r2, 0xC00A         ; &static_data.src_lineno
            ldx     %r2, %r2            ; arg 2 = static_data->src_lineno
            call    utoa                ; convert lineno to string in buffer
            mov     %r0, BUFFER_PTR     ; arg 0 = buf, again
            call    puts                ; print the line number
            hlt                         ; crash the kernel.

; udiv16
;   r0: dividend
;   r2: divisor   ; note NOT r1 !
; returns
;   r0: quotient
;   r1: remainder
;   r2: divisor
; No clobbers.
;
; Perform a 16-bit unsigned division, using a "fast" long division algorithm.
; The divisor is taken in r2 and is returned unchanged, making it easy
; to chain several divisions together "quickly."
udiv16:
            pushx   %r3                 ; save r3
            mov     %r1, 0              ; initial partial remainder is 0
            mov     %r3, 16             ; number of iterations to perform
udiv16_loop:
            addx    %r1, %r1            ; shift the partial remainder one bit left
            addx    %r0, %r0            ; shift dividend left one bit thru carry
            jnc     udiv16_no_qbit      ; if no carry, skip moving bit into partial rem
            orx     %r1, 1              ; move carry into bottom bit of shifted partial rem
udiv16_no_qbit:
            sub     %r1, %r2            ; attempt subtraction from partial remainder
            jnc     udiv16_no_borrow    ; if that subtraction succeeded, set bit of quotient
            add     %r1, %r2            ; otherwise, restore partial remainder
            jmp     udiv16_step         ; and skip setting quotient bit
udiv16_no_borrow:
            orx     %r0, 1              ; set bottom bit of the dividend (growing quotient)
udiv16_step:
            subh    %r3, 1              ; decrement counter
            ja      udiv16_loop         ; continue as long as counter remains > 0
            popx    %r3                 ; otherwise we're done. Restore r3
            ret

; itoa
; utoa
;   r0: char *buffer
;   r1: ignored (for now), should be base
;   r2: the number to convert to a string, int16_t or uint16_t
; returns nothing meaningful
; Standard calling conventions
;
; Convert an integer to a string, storing the resulting string to the buffer.
; If you call 'itoa', the integer is treated as an int16_t. If you call 'utoa',
; the integer is treated as a uint16_t.
itoa:
            testx   %r2, -1             ; test the input number for sign
            jnn     utoa                ; if it's already positive, go straight to utoa
            mov     %r1, '-'            ; otherwise, prepare a minus sign
            sth     %r1, %r0            ; to put in the buffer
            addx    %r0, 1              ; buf++
            rsubx   %r2, 0              ; d = -d
utoa:
            pushx   %ln
            pushx   %r4                 ; wind
            pushx   %r0                 ; save original value of buffer
            mov     %r4, '0'            ; stash '0' for quick access
            mov     %r3, %r0            ; p = buf
            mov     %r0, %r2            ; dividend = d
            mov     %r2, 10             ; divisor = base = 10
itoa_loop:
            call    udiv16              ; r0 = quotient, r1 = remainder, r2 still 10
            addh    %r1, %r4            ; chr = remainder + '0'
            sth     %r1, %r3            ; *p = chr
            addx    %r3, 1              ; p++
            testx   %r0, -1             ; test quotient for zero
            jnz     itoa_loop           ; loop as long as quotient is not yet zero
            sth     %r0, %r3            ; *p = 0, terminate the string
                                        ; now we need to reverse the buffer
            subx    %r3, 1              ; p2 = p - 1
            popx    %r0                 ; p1 = buf
            popx    %r4
            popx    %ln                 ; fully unwind the stack to prepare for
                                        ; quick exit from the reverse loop
            jmp     itoa_rev_check      ; enter loop at check
itoa_rev_loop:
            ldh     %r2, %r0            ; tmp = *p1
            ldh     %r1, %r3            ; r1 = *p2
            sth     %r1, %r0            ; *p1 = *p2
            sth     %r2, %r3            ; *p2 = tmp
            addx    %r0, 1              ; p1++
            subx    %r3, 1              ; p2--
itoa_rev_check:
            cmpx    %r0, %r3            ; p1 <? p2
            jb      itoa_rev_loop       ; loop if yes
            ret                         ; otherwise we're done, return.

; puts
;   r0: const char *str
; returns:
;   r0: pointer to str's nul terminator
;
; r1 is clobbered. When 'puts' returns, r1 is 0.
;
; Print a nul-terminated string to the console device at MMIO address OUTPUT.
puts_L1:
            sth     %r1, OUTPUT         ; putchar(*str)
            addx    %r0, 1              ; ++str
puts:
            ldh     %r1, %r0            ; r1 = *str
            testh   %r1, -1             ; test *str
            jnz     puts_L1             ; loop if *str != 0
            ret                         ; return if *str == 0

syscall_exit:
            pushx   %r1                     ; save status
            call    syscall_exit_with_msg   ; get msg into ln
            .asciiz "Program exited with status "
            .align  2
syscall_exit_with_msg:
            mov     %r0, %r7            ; arg 0 = msg
            call    puts                ; print the msg
            popx    %r2                 ; arg 2 = status
            mov     %r0, 0xC020         ; arg 0 = runtime buffer after kernel data
            mov     %r4, %r0            ; save buffer addr
            call    utoa                ; write str(code) into buffer
            mov     %r0, %r4            ; arg 0 = buffer again
            call    puts                ; print the code
            hlt                         ; terminate

syscall_putuint:
syscall_putsint:
            pushx   %r2                 ; wind stack to save all user registers that we would clobber
            pushx   %r3
            pushx   %r4
            cmph    %r0, 2              ; compare 2*service_no to 2. If it's 2, print unsigned.
            movx    %r2, %r1            ; arg 2 = number
            mov     %r0, 0xC020         ; arg 0 = runtime buffer after kernel data
            movx    %r4, %r0            ; and save this address
            jne     syscall_do_signed   ; if service no is not 2, use itoa
            call    utoa                ; otherwise use utoa
            jmp     syscall_have_a
syscall_do_signed:
            call    itoa
syscall_have_a:                         ; now the buffer has the rep of the number to print
            movx    %r0, %r4            ; get its address back
            call    puts                ; and print the number
            popx    %r4
            popx    %r3
            popx    %r2                 ; unwind
            jmp     syscall_return

syscall_puts:
            movx    %r0, %r1            ; arg 0 = message
            call    puts                ; print it
            jmp     syscall_return

syscall_sbrk:
            mov     %r7, STATIC_DATA_PTR ; r7 = &static_data.break
            ldx     %r0, %r7            ; r0 = static_data->break
            addx    %r1, %r0            ; r1 = static_data->break + numbytes
            addx    %r1, 3
            andx    %r1, -4             ; dword align the new break
            stx     %r1, %r7            ; record the new break
            jmp     syscall_return

syscall_return:
            ; at this point, we know our return address is at the top of OUR stack
            ; and that we need to restore the user's stack pointer from 0xC00A.
            ; We can do whatever we want with r1, but the other registers
            ; have to stay unchanged, including r0 which holds a return value.
            popx    %ln                 ; restore our return address
            mov     %sp, 0xC00A         ; &static_data->user_sp
            ldx     %sp, %sp            ; %sp = static_data->user_sp
            ret


invalid_msg:
            .ascii  "invalid "
empty_str:
empty_msg:                  ; share the NUL-terminator to get empty string
            .half   0

out_of_msg:
            .asciiz "out of "

syntax_msg:
            .asciiz "syntax"

register_msg:
            .asciiz "register"

immediate_msg:
            .asciiz "immediate"

range_msg:
            .asciiz "range"

memory_msg:
            .asciiz "memory"

unknown_symbol_msg:
            .asciiz "unknown symbol "

completed_assembly_msg:
            .asciiz "assembly complete!\n"

exit_with_status_msg:
            .asciiz "program exited with status "

uid_str:
            .asciiz "uid"
ten_str:
            .asciiz "ten"
at_str:
            .asciiz "at"

opcode_table2:
            .half   4
opcode_tables:                  ; pointer directly to 'name'
            .ascii  "or"
            .half   10
            .ascii  "ld"
            .half   11
            .ascii  "st"
opcode_table3short:
            .half   0
            .ascii  "add"
            .half   1
            .ascii  "sub"
            .half   3
            .ascii  "cmp"
            .half   5
            .ascii  "xor"
            .half   6
            .ascii  "and"
            .half   12
            .ascii  "slo"
opcode_table3:
            .half   9   7   2
            .ascii  "mov"
            .half   12  4   3
            .ascii  "pop"
            .half   14  11  3
            .ascii  "hlt"
            .half   15  11  3
            .ascii  "nop"
            .half   16  11  1
            .ascii  "ret"
opcode_table4:
            .half   2
opcode_table4_state:
            .half   5   3
            .ascii  "rsub"
            .half   7   5   3
            .ascii  "test"
            .half   8   5   3
            .ascii  "movz"
            .half   9   5   3
            .ascii  "movs"
            .half   13  2   3
            .ascii  "push"
            .half   16  3   1
            .ascii  "call"
cond_table:
            .half   14
cond_table_name:
            .asciiz "mp"
            .half   0
            .asciiz "z\0"
            .half   0
            .asciiz "e\0"
            .half   1
            .asciiz "nz"
            .half   1
            .asciiz "ne"
            .half   2
            .asciiz "n\0"
            .half   3
            .asciiz "nn"
            .half   4
            .asciiz "c\0"
            .half   4
            .asciiz "b\0"
            .half   5
            .asciiz "nc"
            .half   5
            .asciiz "ae"
            .half   6
            .asciiz "o\0"
            .half   7
            .asciiz "no"
            .half   8
            .asciiz "be"
            .half   9
            .asciiz "a\0"
            .half   10
            .asciiz "l\0"
            .half   11
            .asciiz "ge"
            .half   12
            .asciiz "le"
            .half   13
            .asciiz "g\0"
            .half   14
            .asciiz "\0\0"
