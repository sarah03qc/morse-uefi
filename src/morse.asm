; morse.asm — UEFI x64 (NASM)
; ahora ya lee una oracion hasta Enter y muestra la traduccion completa a Morse
; soporta de momentooo: A–Z, 0–9, espacio (como " / "), Backspace, control de overflow
; convencion MS x64: RCX,RDX,R8,R9 + 32B shadow space

BITS 64
DEFAULT REL

%define OFF_CONIN   0x30          ; EFI_SYSTEM_TABLE->ConIn   (x64)
%define OFF_CONOUT  0x40          ; EFI_SYSTEM_TABLE->ConOut  (x64)

%define FN_OUT_OutputString  0x08  ; ConOut->OutputString(This, CHAR16*)
%define FN_IN_ReadKey        0x08  ; ConIn->ReadKeyStroke(This, EFI_INPUT_KEY*)

%define IN_MAX    160
%define OUT_MAX   2048

section .text
global morseMain

morseMain:
    push rbp
    mov  rbp, rsp
    and  rsp, -16
    sub  rsp, 32

    ; SystemTable en RDX
    mov  r14, [rdx + OFF_CONOUT]   ; ConOut
    mov  r15, [rdx + OFF_CONIN]    ; ConIn

    ; prompt
    mov  rcx, r14
    lea  rdx, [rel msg_prompt]
    call qword [r14 + FN_OUT_OutputString]

    ; lectura
    xor  ebx, ebx                  ; ebx = len = 0
.read_loop:
    mov  rcx, r15
    lea  rdx, [rel keybuf]
    call qword [r15 + FN_IN_ReadKey]
    test rax, rax
    jnz  .read_loop                ; NOT_READY -> reintenta

    movzx eax, word [keybuf + 2]   ; AX = UnicodeChar
    cmp  al, 13                    ; enter
    je   .translate
    cmp  al, 8                     ; backspace
    je   .bksp
    cmp  al, 32                    ; ignorar controles < ' '
    jb   .read_loop

    ; normalizar a MAYUSCULA si 'a'..'z'
    mov  dl, al
    cmp  dl, 'a'
    jb   .store
    cmp  dl, 'z'
    ja   .store
    and  dl, 0xDF                  ; a->A

.store:
    cmp  ebx, IN_MAX
    jae  .read_loop
    mov  [inbuf + rbx], dl
    inc  rbx
    jmp  .read_loop

.bksp:
    test ebx, ebx
    jz   .read_loop
    dec  rbx
    jmp  .read_loop

; traduccion completa 
.translate:
    lea  rdi, [rel outbuf]         ; write ptr
    lea  r9,  [rel outbuf_end]     ; fin de buffer
    xor  r8d, r8d                  ; i = 0

.next_char:
    cmp  r8d, ebx
    jae  .out_ready                ; fin

    mov  dl, [inbuf + r8]          ; c = in[i]

    ; espacio -> " / "
    cmp  dl, ' '
    jne  .not_space
    call append_space_slash_space
    jmp  .after_append

.not_space:
    ; elegir puntero a cadena morse UTF-16 terminada en 0 (no copiar ese 0)
    mov  al, dl
    cmp  al, 'A'
    jb   .try_digit
    cmp  al, 'Z'
    ja   .try_digit
    sub  al, 'A'
    movzx rax, al
    lea  r10, [rel tbl_letters]
    mov  rax, [r10 + rax*8]
    jmp  .copy_morse

.try_digit:
    cmp  dl, '0'
    jb   .use_unknown
    cmp  dl, '9'
    ja   .use_unknown
    sub  dl, '0'
    movzx rax, dl
    lea  r10, [rel tbl_digits]
    mov  rax, [r10 + rax*8]
    jmp  .copy_morse

.use_unknown:
    lea  rax, [rel M_UNK]

.copy_morse:
    ; COPIAR SIN el NUL final de la letra
.copy_loop:
    mov  cx, [rax]                 ; cx = simbolo o 0
    test cx, cx
    jz   .copied                   ; si es NUL, no lo copiamos
    cmp  rdi, r9
    jae  .out_ready
    mov  [rdi], cx
    add  rax, 2
    add  rdi, 2
    jmp  .copy_loop
.copied:

    ; espacio entre letras si existe siguiente y no es espacio
    mov  eax, ebx
    dec  eax                       ; eax = len-1
    cmp  r8d, eax
    jae  .after_append             ; i >= len-1 -> no hay siguiente
    mov  al, [inbuf + r8 + 1]      ; siguiente
    cmp  al, ' '
    je   .after_append
    cmp  rdi, r9
    jae  .out_ready
    mov  word [rdi], 0x20          ; ' '
    add  rdi, 2

.after_append:
    inc  r8d
    jmp  .next_char

.out_ready:
    ; terminar cadena y mostrar
    cmp  rdi, r9
    jae  .no_term
    mov  word [rdi], 0
.no_term:
    mov  rcx, r14
    lea  rdx, [rel msg_result]
    call qword [r14 + FN_OUT_OutputString]

    mov  rcx, r14
    lea  rdx, [rel outbuf]
    call qword [r14 + FN_OUT_OutputString]

    mov  rcx, r14
    lea  rdx, [rel msg_crlf]
    call qword [r14 + FN_OUT_OutputString]

.hang:
    jmp  .hang

; helper: añade " / " 
append_space_slash_space:
    cmp  rdi, r9     ; ' '
    jae  .ret
    mov  word [rdi], 0x20
    add  rdi, 2
    cmp  rdi, r9     ; '/'
    jae  .ret
    mov  word [rdi], '/'
    add  rdi, 2
    cmp  rdi, r9     ; ' '
    jae  .ret
    mov  word [rdi], 0x20
    add  rdi, 2
.ret:
    ret

; datos
section .data
align 8
tbl_letters:
    dq L_A,L_B,L_C,L_D,L_E,L_F,L_G,L_H,L_I,L_J,L_K,L_L,L_M
    dq L_N,L_O,L_P,L_Q,L_R,L_S,L_T,L_U,L_V,L_W,L_X,L_Y,L_Z
tbl_digits:
    dq D_0,D_1,D_2,D_3,D_4,D_5,D_6,D_7,D_8,D_9

align 2
msg_prompt: dw 'E','s','c','r','i','b','e',' ','u','n','a',' ','o','r','a','c','i','o','n',',',' ','E','n','t','e','r',' ','p','a','r','a',' ','t','r','a','d','u','c','i','r',13,10,0
msg_result: dw 'M','o','r','s','e',':',' ',0
msg_crlf:   dw 13,10,0

M_UNK: dw '?',0

; letras
L_A: dw '.','_',0
L_B: dw '_','.', '.', '.',0
L_C: dw '_','.', '_','.',0
L_D: dw '_','.', '.',0
L_E: dw '.',0
L_F: dw '.', '.', '_','.',0
L_G: dw '_','_', '.',0
L_H: dw '.', '.', '.', '.',0
L_I: dw '.', '.',0
L_J: dw '.', '_','_','_',0
L_K: dw '_','.', '_',0
L_L: dw '.', '_','.', '.',0
L_M: dw '_','_',0
L_N: dw '_','.',0
L_O: dw '_','_','_',0
L_P: dw '.', '_','.', '_',0
L_Q: dw '_','_','.', '_',0
L_R: dw '.', '_','.',0
L_S: dw '.', '.', '.',0
L_T: dw '_',0
L_U: dw '.', '.', '_',0
L_V: dw '.', '.', '.', '_',0
L_W: dw '.', '_','_',0
L_X: dw '_','.', '.', '_',0
L_Y: dw '_','.', '_','_',0
L_Z: dw '_','_','.', '.',0

; digitos
D_0: dw '_','_','_','_','_',0
D_1: dw '.', '_','_','_','_',0
D_2: dw '.', '.', '_','_','_',0
D_3: dw '.', '.', '.', '_','_',0
D_4: dw '.', '.', '.', '.', '_',0
D_5: dw '.', '.', '.', '.', '.',0
D_6: dw '_','.', '.', '.', '.',0
D_7: dw '_','_','.', '.', '.',0
D_8: dw '_','_','_','.', '.',0
D_9: dw '_','_','_','_','.',0

; buffers
align 2
inbuf:      times IN_MAX db 0
outbuf:     times OUT_MAX dw 0
outbuf_end:

; key buffer (ScanCode, UnicodeChar)
keybuf:     dw 0,0

section .reloc
section .note.GNU-stack noalloc noexec nowrite


