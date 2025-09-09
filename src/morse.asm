; UEFI x86_64 - de momento imprimimos Holis

BITS 64
DEFAULT REL

; offsets que usa el firmware 
%define ST_CONOUT_OFF       64        ; = 0x40  (EFI_SYSTEM_TABLE.ConOut)
%define VTBL_OutputString    8        ; = 0x08  (metodo OutputString)

section .data
    align 2
msg_hello:  dw 'H','o','l','i','s',0

section .text
    global  morseMain

morseMain:
    ; reservar shadow space (ABI x64)
    sub     rsp, 32

    ; RCX=imageHandle (no se usa)
    ; RDX=SystemTable -> leer puntero a SimpleTextOutput (ConOut)
    mov     r8,  [rdx + ST_CONOUT_OFF]   ; r8 = ConOut
    mov     rcx, r8                      ; this = ConOut
    lea     rdx, [rel msg_hello]         ; 2º arg = CHAR16*
    call    qword [r8 + VTBL_OutputString]

    add     rsp, 32

.halt:
    jmp     .halt                        ; quedarse en pantalla

section .reloc
; se ocupa por los cargadores UEFI 
