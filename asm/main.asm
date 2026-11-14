; ---------------------------------------------------------------------------
; mysqlbinlog-asm : Phase 1 offline MySQL binlog parser in x86-64 NASM.
;
; Build (CI only, never locally):
;   nasm -felf64 asm/main.asm -o asm/main.o
;   gcc -no-pie -o asm/mysqlbinlog-asm asm/main.o
;
; Design notes:
;   * SysV AMD64 ABI, `main` entry (libc linked, -no-pie), so we can use
;     fopen/fread/printf for I/O and integer formatting.
;   * ALL parser state lives in .bss globals: libc calls clobber caller-saved
;     registers, so nothing is kept in registers across a call.
;   * Helpers (le_n/crc32/strcmp_/take_le/skip_bytes/lenenc) are leaf routines
;     (they never call libc), so stack alignment is only maintained at main's
;     frame, where every libc call is made.
;   * x86 is little-endian, but le_n is still a portable byte loop.
;   * Strings in the controlled subset are clean ASCII (no quotes/backslashes/
;     control chars), so %.*s needs no JSON escaping to match the golden file.
; ---------------------------------------------------------------------------

BITS 64

extern printf, fopen, fseek, ftell, fread, fclose, exit
global main

; Load n little-endian bytes at [%2] into %1 (64-bit).
; %3 = n (register or immediate; must NOT be rcx/rax/r8).
%macro LOADLE 3
    xor %1, %1
    mov rcx, %3
%%ll_loop:
    test rcx, rcx
    jz %%ll_done
    dec rcx
    shl %1, 8
    movzx r8d, byte [%2 + rcx]
    or %1, r8
    jmp %%ll_loop
%%ll_done:
%endmacro

; printf a plain literal (no '%' inside) to stdout.
%macro PLIT 1
    lea rdi, [rel %1]
    xor eax, eax
    call printf wrt ..plt
%endmacro

section .rodata

; ---- full printf format strings (<= 5 varargs each) ----
f_fde:        db '{"type":"FORMAT_DESCRIPTION_EVENT","timestamp":%llu,"binlog_version":%llu,"server_version":"%.*s","checksum_alg":%llu}', 10, 0
f_unknown:    db '{"type":"UNKNOWN","timestamp":%llu,"type_id":%llu,"event_size":%llu}', 10, 0
f_gtid:       db '{"type":"GTID_LOG_EVENT","timestamp":%llu,"gno":%llu,"sid":"%.*s"}', 10, 0
f_query:      db '{"type":"QUERY_EVENT","timestamp":%llu,"db":"%.*s","query":"%.*s"}', 10, 0
f_rowsquery:  db '{"type":"ROWS_QUERY_LOG_EVENT","timestamp":%llu,"query":"%.*s"}', 10, 0
f_tmap1:      db '{"type":"TABLE_MAP_EVENT","timestamp":%llu,"table_id":%llu,"db":"%.*s"', 0
f_tmap2:      db ',"table":"%.*s","column_count":%llu,"column_types":[', 0
f_rows1:      db '{"type":"%s","timestamp":%llu,"table_id":%llu,"db":"%.*s"', 0
f_rows2:      db ',"table":"%.*s","rows":[', 0
f_xid:        db '{"type":"XID_EVENT","timestamp":%llu,"xid":%llu}', 10, 0
f_rotate:     db '{"type":"ROTATE_EVENT","timestamp":%llu,"position":%llu,"next_file":"%.*s"}', 10, 0
f_qstr:       db '"%.*s"', 0
f_num:        db '%llu', 0

; ---- plain literal fragments ----
f_comma:      db ',', 0
f_lbrack:     db '[', 0
f_rbrack:     db ']', 0
f_null:       db 'null', 0
f_endrows:    db ']}', 10, 0
lit_write:    db 'WRITE_ROWS_EVENT_V2', 0
lit_update:   db 'UPDATE_ROWS_EVENT_V2', 0
lit_delete:   db 'DELETE_ROWS_EVENT_V2', 0

lit_file:     db '--file', 0
lit_selftest: db '--self-test', 0
lit_help:     db '--help', 0
lit_rb:       db 'rb', 0
hexchars:     db '0123456789abcdef'

lit_usage:       db 'Usage: mysqlbinlog-asm --file <path> [--format jsonl]', 10, 0
lit_openfail:    db 'cannot open file', 10, 0
lit_badmagic:    db 'parse failed: invalid', 10, 0
lit_truncated:   db 'parse failed: truncated', 10, 0
lit_checksum:    db 'parse failed: checksum', 10, 0
lit_noschema:    db 'parse failed: no_schema', 10, 0
lit_unsupported: db 'parse failed: unsupported', 10, 0
lit_st_ok:       db 'asm unit tests ok', 10, 0
lit_st_fail:     db 'asm self-test FAILED', 10, 0

lit_crcvec:      db '123456789'          ; 9 bytes, not NUL-terminated

; crafted 19-byte header for --self-test
hdr_test: db 0x00, 0xF1, 0x53, 0x65, 15, 1, 0, 0, 0, 119, 0, 0, 0, 123, 0, 0, 0, 0, 0

section .bss
inbuf            resb 65536
tmp              resb 4096
argc_g           resq 1
argv_g           resq 1
path             resq 1
fp               resq 1
inlen            resq 1
pos              resq 1
es               resq 1
etype            resq 1
stamps           resq 1
body             resq 1
blen             resq 1
cur              resq 1
brem             resq 1
calccrc          resd 1

schema_ok        resq 1
schema_tid       resq 1
schema_db        resq 1
schema_dblen     resq 1
schema_tbl       resq 1
schema_tbllen    resq 1
schema_cc        resq 1
schema_nullable  resq 1
schema_types     resb 16
schema_vlen      resb 16

f_bv             resq 1
f_alg            resq 1
svptr            resq 1
svlen            resq 1
g_sidptr         resq 1
g_gno            resq 1
q_dbl            resq 1
q_svl            resq 1
q_dbp            resq 1
q_ql             resq 1
q_qp             resq 1
rq_len           resq 1
rq_ptr           resq 1
t_tid            resq 1
t_dbl            resq 1
t_dbp            resq 1
t_tbl            resq 1
t_tbp            resq 1
t_cc             resq 1
t_i              resq 1
t_mdlen          resq 1
t_mdstart        resq 1
t_nb             resq 1
t_nullbm         resq 1
t_nullable       resq 1
t_lb             resb 1
r_tid            resq 1
r_cc             resq 1
r_bm             resq 1
r_present        resq 1
r_nbs            resq 1
r_nullbm         resq 1
r_slen           resq 1
typename         resq 1

section .text

; ---------------------------------------------------------------------------
; Leaf helpers (never call libc; safe to call at any stack alignment).
; ---------------------------------------------------------------------------

; rdi = ptr, rsi = n -> rax = LE value
le_n:
    LOADLE rax, rdi, rsi
    ret

; rdi = s1, rsi = s2 -> rax = 0 if equal, else 1
strcmp_:
strcmp_loop:
    mov al, [rdi]
    mov dl, [rsi]
    cmp al, dl
    jne strcmp_diff
    test al, al
    jz strcmp_equal
    inc rdi
    inc rsi
    jmp strcmp_loop
strcmp_diff:
    mov eax, 1
    ret
strcmp_equal:
    xor eax, eax
    ret

; rdi = ptr, rsi = len -> eax = CRC-32 (IEEE)
crc32:
    mov eax, 0xFFFFFFFF
    xor rcx, rcx
crc_outer:
    cmp rcx, rsi
    jae crc_done
    xor edx, edx
    mov dl, [rdi + rcx]
    xor eax, edx
    xor r8, r8
crc_inner:
    cmp r8, 8
    jae crc_next
    mov r9d, eax
    and r9d, 1
    neg r9d
    and r9d, 0xEDB88320
    shr eax, 1
    xor eax, r9d
    inc r8
    jmp crc_inner
crc_next:
    inc rcx
    jmp crc_outer
crc_done:
    not eax
    ret

; rsi = n -> rax = value; advances [cur], decrements [brem]
take_le:
    mov rdi, [rel cur]
    LOADLE rax, rdi, rsi
    add qword [rel cur], rsi
    sub qword [rel brem], rsi
    ret

; rsi = n; advances [cur], decrements [brem]
skip_bytes:
    add qword [rel cur], rsi
    sub qword [rel brem], rsi
    ret

; -> rax = length-encoded integer; advances [cur], decrements [brem]
lenenc:
    mov rdi, [rel cur]
    movzx rax, byte [rdi]
    inc qword [rel cur]
    dec qword [rel brem]
    cmp al, 0xFB
    jb lenenc_done
    je lenenc_zero
    cmp al, 0xFC
    je lenenc_two
    cmp al, 0xFD
    je lenenc_three
    cmp al, 0xFE
    je lenenc_eight
    xor eax, eax
    ret
lenenc_zero:
    xor eax, eax
    ret
lenenc_two:
    mov rsi, 2
    call take_le
    ret
lenenc_three:
    mov rsi, 3
    call take_le
    ret
lenenc_eight:
    mov rsi, 8
    call take_le
    ret
lenenc_done:
    ret

; ---------------------------------------------------------------------------
; main
; ---------------------------------------------------------------------------
main:
    push rbp
    mov rbp, rsp
    sub rsp, 32                    ; rsp stays 16-aligned for all libc calls
    mov [rel argc_g], rdi
    mov [rel argv_g], rsi

    ; ---- argument scan ----
    mov r12, [rel argv_g]
    mov r13, 1
arg_loop:
    cmp r13, [rel argc_g]
    jae arg_done
    mov rdi, [r12 + r13 * 8]
    lea rsi, [rel lit_file]
    call strcmp_
    test rax, rax
    jnz arg_not_file
    inc r13
    mov rax, [r12 + r13 * 8]
    mov [rel path], rax
    jmp arg_next
arg_not_file:
    mov rdi, [r12 + r13 * 8]
    lea rsi, [rel lit_selftest]
    call strcmp_
    test rax, rax
    jnz arg_not_selftest
    jmp selftest
arg_not_selftest:
    mov rdi, [r12 + r13 * 8]
    lea rsi, [rel lit_help]
    call strcmp_
    test rax, rax
    jnz arg_next
    PLIT lit_usage
    mov rdi, 0
    call exit wrt ..plt
arg_next:
    inc r13
    jmp arg_loop
arg_done:
    cmp qword [rel path], 0
    jne open_file
    PLIT lit_usage
    mov rdi, 2
    call exit wrt ..plt

    ; ---- read file ----
open_file:
    mov rdi, [rel path]
    lea rsi, [rel lit_rb]
    call fopen wrt ..plt
    test rax, rax
    jz open_fail
    mov [rel fp], rax
    mov rdi, rax
    xor esi, esi
    mov edx, 2                     ; SEEK_END
    call fseek wrt ..plt
    mov rdi, [rel fp]
    call ftell wrt ..plt
    mov [rel inlen], rax
    mov rdi, [rel fp]
    xor esi, esi
    xor edx, edx                   ; SEEK_SET
    call fseek wrt ..plt
    lea rdi, [rel inbuf]
    mov esi, 1
    mov rdx, [rel inlen]
    mov rcx, [rel fp]
    call fread wrt ..plt
    mov rdi, [rel fp]
    call fclose wrt ..plt

    cmp dword [rel inbuf], 0x6E6962FE
    jne bad_magic
    mov qword [rel pos], 4

    ; ---- event loop ----
ev_loop:
    mov rax, [rel pos]
    cmp rax, [rel inlen]
    jae done_ok
    lea r12, [rel inbuf]
    add r12, [rel pos]             ; r12 = event base

    ; event_size = le(base+9, 4)
    lea rdi, [r12 + 9]
    mov rsi, 4
    call le_n
    mov [rel es], rax
    cmp qword [rel es], 23
    jb truncated
    mov rax, [rel pos]
    add rax, [rel es]
    cmp rax, [rel inlen]
    ja truncated

    ; CRC32 over header+body (event_size-4 bytes)
    mov rdi, r12
    mov rsi, [rel es]
    sub rsi, 4
    call crc32
    mov dword [rel calccrc], eax
    mov rdi, r12
    add rdi, [rel es]
    sub rdi, 4
    mov rsi, 4
    call le_n
    mov r9d, dword [rel calccrc]
    cmp r9d, eax
    jne checksum_err

    ; header fields
    movzx rax, byte [r12 + 4]
    mov [rel etype], rax
    mov rdi, r12
    mov rsi, 4
    call le_n
    mov [rel stamps], rax

    ; body window
    lea rax, [r12 + 19]
    mov [rel body], rax
    mov [rel cur], rax
    mov rax, [rel es]
    sub rax, 23
    mov [rel blen], rax
    mov [rel brem], rax

    ; dispatch
    mov rax, [rel etype]
    cmp rax, 15
    je h_fde
    cmp rax, 33
    je h_gtid
    cmp rax, 2
    je h_query
    cmp rax, 29
    je h_rowsquery
    cmp rax, 19
    je h_tmap
    cmp rax, 30
    je h_rows
    cmp rax, 31
    je h_rows
    cmp rax, 32
    je h_rows
    cmp rax, 16
    je h_xid
    cmp rax, 4
    je h_rotate
    jmp h_unknown

; ---- FORMAT_DESCRIPTION_EVENT (15) ----
h_fde:
    mov rsi, 2
    call take_le
    mov [rel f_bv], rax
    mov rax, [rel cur]
    mov [rel svptr], rax
    xor rcx, rcx
fde_svscan:
    cmp rcx, 50
    jae fde_svscan_done
    mov rdi, [rel svptr]
    cmp byte [rdi + rcx], 0
    je fde_svscan_done
    inc rcx
    jmp fde_svscan
fde_svscan_done:
    mov [rel svlen], rcx
    mov rsi, 50
    call skip_bytes
    mov rdi, [rel body]
    add rdi, [rel blen]
    sub rdi, 1
    movzx rax, byte [rdi]
    mov [rel f_alg], rax

    lea rdi, [rel f_fde]
    mov rsi, [rel stamps]
    mov rdx, [rel f_bv]
    mov rcx, [rel svlen]
    mov r8, [rel svptr]
    mov r9, [rel f_alg]
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- GTID_LOG_EVENT (33) ----
h_gtid:
    mov rsi, 1
    call take_le                   ; flags
    mov rax, [rel cur]
    mov [rel g_sidptr], rax
    mov rsi, 16
    call skip_bytes
    ; build 32-char lowercase hex into tmp
    mov rdi, [rel g_sidptr]
    lea r8, [rel tmp]
    lea r11, [rel hexchars]
    xor rcx, rcx
gtid_hexloop:
    cmp rcx, 16
    jae gtid_hexdone
    movzx rax, byte [rdi + rcx]
    mov r9, rax
    shr r9, 4
    movzx r10d, byte [r11 + r9]
    mov [r8 + rcx * 2], r10b
    and rax, 15
    movzx r10d, byte [r11 + rax]
    mov [r8 + rcx * 2 + 1], r10b
    inc rcx
    jmp gtid_hexloop
gtid_hexdone:
    mov rsi, 8
    call take_le
    mov [rel g_gno], rax
    lea rdi, [rel f_gtid]
    mov rsi, [rel stamps]
    mov rdx, [rel g_gno]
    mov rcx, 32
    lea r8, [rel tmp]
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- QUERY_EVENT (2) ----
h_query:
    mov rsi, 4
    call take_le                   ; thread_id
    mov rsi, 4
    call take_le                   ; exec_time
    mov rsi, 1
    call take_le
    mov [rel q_dbl], rax
    mov rsi, 2
    call take_le                   ; error_code
    mov rsi, 2
    call take_le
    mov [rel q_svl], rax
    mov rsi, [rel q_svl]
    call skip_bytes                ; status_vars
    mov rax, [rel cur]
    mov [rel q_dbp], rax
    mov rsi, [rel q_dbl]
    call skip_bytes                ; db
    mov rsi, 1
    call take_le                   ; trailing NUL
    mov rax, [rel cur]
    mov [rel q_qp], rax
    mov rax, [rel brem]
    mov [rel q_ql], rax

    lea rdi, [rel f_query]
    mov rsi, [rel stamps]
    mov rdx, [rel q_dbl]
    mov rcx, [rel q_dbp]
    mov r8, [rel q_ql]
    mov r9, [rel q_qp]
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- ROWS_QUERY_LOG_EVENT (29) ----
h_rowsquery:
    call lenenc
    mov [rel rq_len], rax
    mov rax, [rel cur]
    mov [rel rq_ptr], rax
    mov rsi, [rel rq_len]
    call skip_bytes
    lea rdi, [rel f_rowsquery]
    mov rsi, [rel stamps]
    mov rdx, [rel rq_len]
    mov rcx, [rel rq_ptr]
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- TABLE_MAP_EVENT (19) ----
h_tmap:
    mov rsi, 6
    call take_le
    mov [rel t_tid], rax
    mov rsi, 2
    call take_le                   ; flags
    mov rsi, 1
    call take_le
    mov [rel t_dbl], rax
    mov rax, [rel cur]
    mov [rel t_dbp], rax
    mov rsi, [rel t_dbl]
    call skip_bytes
    mov rsi, 1
    call take_le                   ; NUL
    mov rsi, 1
    call take_le
    mov [rel t_tbl], rax
    mov rax, [rel cur]
    mov [rel t_tbp], rax
    mov rsi, [rel t_tbl]
    call skip_bytes
    mov rsi, 1
    call take_le                   ; NUL
    call lenenc
    mov [rel t_cc], rax

    ; column_types[]
    mov qword [rel t_i], 0
tmap_typeloop:
    mov rax, [rel t_i]
    cmp rax, [rel t_cc]
    jae tmap_typedone
    mov rsi, 1
    call take_le
    mov rcx, [rel t_i]
    lea r11, [rel schema_types]
    mov [r11 + rcx], al
    inc qword [rel t_i]
    jmp tmap_typeloop
tmap_typedone:
    call lenenc
    mov [rel t_mdlen], rax
    mov rax, [rel cur]
    mov [rel t_mdstart], rax

    ; metadata: VARCHAR contributes a 2-byte maxlen
    mov qword [rel t_i], 0
tmap_mdloop:
    mov rax, [rel t_i]
    cmp rax, [rel t_cc]
    jae tmap_mddone
    mov rcx, [rel t_i]
    lea r11, [rel schema_types]
    movzx rax, byte [r11 + rcx]
    cmp al, 15
    jne tmap_md_skip
    mov rsi, 2
    call take_le
    cmp rax, 255
    ja tmap_md_two
    mov byte [rel t_lb], 1
    jmp tmap_md_set
tmap_md_two:
    mov byte [rel t_lb], 2
tmap_md_set:
    mov rcx, [rel t_i]
    mov al, byte [rel t_lb]
    lea r11, [rel schema_vlen]
    mov [r11 + rcx], al
    jmp tmap_md_next
tmap_md_skip:
    mov rcx, [rel t_i]
    lea r11, [rel schema_vlen]
    mov byte [r11 + rcx], 0
tmap_md_next:
    inc qword [rel t_i]
    jmp tmap_mdloop
tmap_mddone:
    ; cur = mdstart + mdlen ; recompute brem
    mov rax, [rel t_mdstart]
    add rax, [rel t_mdlen]
    mov [rel cur], rax
    mov rax, [rel body]
    add rax, [rel blen]
    sub rax, [rel cur]
    mov [rel brem], rax

    ; null_bitmap
    mov rax, [rel t_cc]
    add rax, 7
    shr rax, 3
    mov [rel t_nb], rax
    mov rsi, rax
    call take_le
    mov [rel t_nullbm], rax
    mov qword [rel t_nullable], 0
    mov qword [rel t_i], 0
tmap_popc:
    mov rax, [rel t_i]
    cmp rax, [rel t_cc]
    jae tmap_popdone
    mov rcx, [rel t_i]
    mov rax, [rel t_nullbm]
    bt rax, rcx
    jnc tmap_popnext
    inc qword [rel t_nullable]
tmap_popnext:
    inc qword [rel t_i]
    jmp tmap_popc
tmap_popdone:
    ; publish schema
    mov rax, [rel t_tid]
    mov [rel schema_tid], rax
    mov rax, [rel t_dbl]
    mov [rel schema_dblen], rax
    mov rax, [rel t_dbp]
    mov [rel schema_db], rax
    mov rax, [rel t_tbl]
    mov [rel schema_tbllen], rax
    mov rax, [rel t_tbp]
    mov [rel schema_tbl], rax
    mov rax, [rel t_cc]
    mov [rel schema_cc], rax
    mov rax, [rel t_nullable]
    mov [rel schema_nullable], rax
    mov qword [rel schema_ok], 1

    lea rdi, [rel f_tmap1]
    mov rsi, [rel stamps]
    mov rdx, [rel t_tid]
    mov rcx, [rel t_dbl]
    mov r8, [rel t_dbp]
    xor eax, eax
    call printf wrt ..plt
    lea rdi, [rel f_tmap2]
    mov rsi, [rel t_tbl]
    mov rdx, [rel t_tbp]
    mov rcx, [rel t_cc]
    xor eax, eax
    call printf wrt ..plt

    mov qword [rel t_i], 0
tmap_arr:
    mov rax, [rel t_i]
    cmp rax, [rel t_cc]
    jae tmap_arrdone
    cmp qword [rel t_i], 0
    je tmap_arr_value
    PLIT f_comma
tmap_arr_value:
    lea rdi, [rel f_num]
    mov rcx, [rel t_i]
    lea r11, [rel schema_types]
    xor rsi, rsi
    mov sil, byte [r11 + rcx]
    xor eax, eax
    call printf wrt ..plt
    inc qword [rel t_i]
    jmp tmap_arr
tmap_arrdone:
    PLIT f_endrows
    jmp next_event

; ---- ROWS_EVENT_V2 (30/31/32) ----
h_rows:
    mov rax, [rel etype]
    cmp rax, 30
    je rows_name_w
    cmp rax, 31
    je rows_name_u
    lea rax, [rel lit_delete]
    jmp rows_name_done
rows_name_w:
    lea rax, [rel lit_write]
    jmp rows_name_done
rows_name_u:
    lea rax, [rel lit_update]
rows_name_done:
    mov [rel typename], rax

    mov rsi, 6
    call take_le
    mov [rel r_tid], rax
    mov rsi, 2
    call take_le                   ; flags
    mov rsi, 2
    call take_le                   ; extra_data_len
    sub rax, 2
    mov rsi, rax
    call skip_bytes                ; extra_data
    call lenenc
    mov [rel r_cc], rax
    mov rax, [rel r_cc]
    add rax, 7
    shr rax, 3
    mov [rel r_bm], rax
    mov rsi, rax
    call take_le                   ; columns_present bitmap1
    mov [rel r_present], rax
    mov rax, [rel etype]
    cmp rax, 31
    jne rows_no_bm2
    mov rsi, [rel r_bm]
    call take_le                   ; bitmap2 (equal)
rows_no_bm2:
    cmp qword [rel schema_ok], 0
    je no_schema
    mov rax, [rel r_tid]
    cmp rax, [rel schema_tid]
    jne no_schema
    mov rax, [rel schema_nullable]
    add rax, 7
    shr rax, 3
    mov [rel r_nbs], rax

    lea rdi, [rel f_rows1]
    mov rsi, [rel typename]
    mov rdx, [rel stamps]
    mov rcx, [rel r_tid]
    mov r8, [rel schema_dblen]
    mov r9, [rel schema_db]
    xor eax, eax
    call printf wrt ..plt
    lea rdi, [rel f_rows2]
    mov rsi, [rel schema_tbllen]
    mov rdx, [rel schema_tbl]
    xor eax, eax
    call printf wrt ..plt

rows_rowloop:
    cmp qword [rel brem], 0
    je rows_rowdone
    mov rsi, [rel r_nbs]
    call take_le                   ; null_bitmap
    mov [rel r_nullbm], rax
    PLIT f_lbrack
    xor r14, r14                   ; column index i (callee-saved)
    mov r15, 1                     ; first flag
rows_collow:
    mov rax, [rel schema_cc]
    cmp r14, rax
    jae rows_coldone
    mov rax, [rel r_present]
    bt rax, r14
    jnc rows_colnext
    cmp r15, 0
    je rows_nocomma
    PLIT f_comma
rows_nocomma:
    mov r15, 0
    mov rax, [rel r_nullbm]
    bt rax, r14
    jc rows_nullval
    lea r11, [rel schema_types]
    movzx rax, byte [r11 + r14]
    cmp al, 8
    je rows_i64
    cmp al, 3
    je rows_i32
    cmp al, 15
    je rows_varchar
    jmp unsupported
rows_i64:
    mov rsi, 8
    call take_le
    mov rsi, rax
    lea rdi, [rel f_num]
    xor eax, eax
    call printf wrt ..plt
    jmp rows_colnext
rows_i32:
    mov rsi, 4
    call take_le
    mov rsi, rax
    lea rdi, [rel f_num]
    xor eax, eax
    call printf wrt ..plt
    jmp rows_colnext
rows_varchar:
    lea r11, [rel schema_vlen]
    movzx rsi, byte [r11 + r14]
    test rsi, rsi
    jnz rows_vlb_ok
    mov rsi, 1
rows_vlb_ok:
    call take_le                   ; slen
    mov [rel r_slen], rax
    mov rdx, [rel cur]            ; string pointer for printf
    mov r8, [rel r_slen]
    add qword [rel cur], r8
    sub qword [rel brem], r8
    lea rdi, [rel f_qstr]
    mov rsi, [rel r_slen]
    xor eax, eax
    call printf wrt ..plt
    jmp rows_colnext
rows_nullval:
    PLIT f_null
rows_colnext:
    inc r14
    jmp rows_collow
rows_coldone:
    PLIT f_rbrack
    cmp qword [rel brem], 0
    je rows_rowdone
    PLIT f_comma
    jmp rows_rowloop
rows_rowdone:
    PLIT f_endrows
    jmp next_event

; ---- XID_EVENT (16) ----
h_xid:
    mov rsi, 8
    call take_le
    lea rdi, [rel f_xid]
    mov rsi, [rel stamps]
    mov rdx, rax
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- ROTATE_EVENT (4) ----
h_rotate:
    mov rsi, 8
    call take_le
    mov [rel r_slen], rax          ; reuse as position
    mov r8, [rel cur]
    mov rcx, [rel brem]
    lea rdi, [rel f_rotate]
    mov rsi, [rel stamps]
    mov rdx, [rel r_slen]
    ; rcx = nflen, r8 = nfptr
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

; ---- UNKNOWN ----
h_unknown:
    lea rdi, [rel f_unknown]
    mov rsi, [rel stamps]
    mov rdx, [rel etype]
    mov rcx, [rel es]
    xor eax, eax
    call printf wrt ..plt
    jmp next_event

next_event:
    mov rax, [rel pos]
    add rax, [rel es]
    mov [rel pos], rax
    jmp ev_loop

; ---- --self-test (CRC vector + header fields) ----
selftest:
    lea rdi, [rel lit_crcvec]
    mov rsi, 9
    call crc32
    cmp eax, 0xCBF43926
    jne selftest_fail
    lea rdi, [rel hdr_test]
    mov rsi, 4
    call le_n
    cmp rax, 1700000000
    jne selftest_fail
    movzx rax, byte [rel hdr_test + 4]
    cmp al, 15
    jne selftest_fail
    lea rdi, [rel hdr_test + 9]
    mov rsi, 4
    call le_n
    cmp rax, 119
    jne selftest_fail
    PLIT lit_st_ok
    mov rdi, 0
    call exit wrt ..plt
selftest_fail:
    PLIT lit_st_fail
    mov rdi, 1
    call exit wrt ..plt

; ---- error / success exits ----
open_fail:
    PLIT lit_openfail
    mov rdi, 2
    call exit wrt ..plt
bad_magic:
    PLIT lit_badmagic
    mov rdi, 1
    call exit wrt ..plt
truncated:
    PLIT lit_truncated
    mov rdi, 1
    call exit wrt ..plt
checksum_err:
    PLIT lit_checksum
    mov rdi, 1
    call exit wrt ..plt
no_schema:
    PLIT lit_noschema
    mov rdi, 1
    call exit wrt ..plt
unsupported:
    PLIT lit_unsupported
    mov rdi, 1
    call exit wrt ..plt
done_ok:
    mov rdi, 0
    call exit wrt ..plt
