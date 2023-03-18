;
.set OUTPUT 3

.macro putc 1
            mov %rx0, {0}
            stx %r0, OUTPUT
.endmacro


            putc 'H'
            putc 'e'
            putc 'l'
            putc 'l'
            putc 'o'
            putc ','
            putc ' '
            putc 'W'
            putc 'o'
            putc 'r'
            putc 'l'
            putc 'd'
            putc '!'