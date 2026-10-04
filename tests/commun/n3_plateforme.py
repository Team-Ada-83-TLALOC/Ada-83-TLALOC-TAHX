# Plateforme des tests N3_xxx : image combinée (image HX, handlers des services, bloc de
# démarrage, VTB, FSCR), chargée en 0x400000, et valeurs attendues (tx_run).
#   python3 n3_plateforme.py <image.hxexe> <sortie.bin> <constantes.txt>
# Les handlers rendent PUT_CHAR, PUT_STR et FILE_WRITE comme l'hôte de tx_run
# (machine-trap.adb), avec les effets de pile des macros SYS_xxx, en écrivant chaque
# octet à l'adresse CONSOLE (observée par le banc), puis RTX.
import struct, sys
BASE      = 0x400000
HANDLERS  = 0x410000
BOOT      = 0x420000
VTB       = 0x421000
FSCR      = 0x421800
SCR_LEN, SCR_PTR, SCR_RES = 0x421900, 0x421908, 0x421910
CONSOLE   = 0x421A00
FILE_END  = 0x422000
DSP0, LIM_DSP = 0x430000, 0x43F000            # pile data   [0x430000, 0x440000)
RSP0, LIM_RSP = 0x448000, 0x441000            # retours     [0x440000, 0x448000)
COP0, LIM_CSP = 0x450000, 0x4CF000            # co-pile     [0x450000, 0x4D0000)
HP0,  LIM_HP  = 0x4E0000, 0x4D0000            # tas         [0x4D0000, 0x4E0000)
MEM_END       = 0x4E0000

# --- assembleur HX (deux passes, étiquettes)
OPS = dict(ADD=0x10, SUB=0x12, INC=0x11, DEC=0x13, CGT=0x09, CLAMP0=0x07, DROP=0x30, DUP=0x31,
           OVER=0x32, LD=0x52, LQ=0x53, SB=0x60, SQ=0x63, ULB=0x70, RTX=0xFF)
class Asm:
    def __init__(s, org): s.org = org; s.items = []; s.labels = {}
    def op(s, n): s.items.append(('op', n))
    def li8(s, v): s.items.append(('li8', v))
    def li32(s, v): s.items.append(('li32', v))
    def bf(s, l): s.items.append(('bf', l))
    def bra(s, l): s.items.append(('bra', l))
    def label(s, l): s.items.append(('label', l))
    def size(s, it): return {'op': 1, 'li8': 2, 'li32': 5, 'bf': 3, 'bra': 3, 'label': 0}[it[0]]
    def build(s):
        pc = s.org
        for it in s.items:
            if it[0] == 'label': s.labels[it[1]] = pc
            pc += s.size(it)
        out = bytearray(); pc = s.org
        for it in s.items:
            k = it[0]
            if k == 'op': out += bytes([OPS[it[1]]])
            elif k == 'li8': out += bytes([0xC0, it[1] & 0xFF])
            elif k == 'li32': out += bytes([0xC2]) + struct.pack('>i', it[1])
            elif k in ('bf', 'bra'):                       # BR16 : cible = pc + 3 + disp
                d = s.labels[it[1]] - (pc + 3)
                out += bytes([0xE9 if k == 'bf' else 0xE1]) + struct.pack('>h', d)
            pc += s.size(it)
        return bytes(out)
    # un mot de la zone de travail
    def save_drop(s, a): s.li32(a); s.op('OVER'); s.op('SQ'); s.op('DROP')   # ( x -- ), M64[a] := x
    def load(s, a): s.li32(a); s.op('LQ')                                  # ( -- M64[a] )
    def copy(s, tag):                                                      # SCR_LEN octets dès SCR_PTR
        s.label('L' + tag)
        s.load(SCR_LEN); s.li8(0); s.op('CGT'); s.bf('E' + tag)
        s.load(SCR_PTR); s.op('ULB'); s.li32(CONSOLE); s.op('OVER'); s.op('SB'); s.op('DROP')
        s.load(SCR_PTR); s.op('INC'); s.save_drop(SCR_PTR)
        s.load(SCR_LEN); s.op('DEC'); s.save_drop(SCR_LEN)
        s.bra('L' + tag)
        s.label('E' + tag)

def handlers():
    vec = {}; code = bytearray(); org = HANDLERS
    # PUT_CHAR ( c -- )
    a = Asm(org); a.li32(CONSOLE); a.op('OVER'); a.op('SB'); a.op('DROP'); a.op('RTX')
    b = a.build(); vec[2] = org; code += b; org += len(b)
    # PUT_STR ( @doublet -- ) : M64[d] pointeur ; info = M64[d+8] ; long = M32[info+12] + 1 - M32[info+8]
    a = Asm(org)
    a.op('DUP'); a.op('LQ'); a.save_drop(SCR_PTR)
    a.li8(8); a.op('ADD'); a.op('LQ')
    a.op('DUP'); a.li8(12); a.op('ADD'); a.op('LD')
    a.op('OVER'); a.li8(8); a.op('ADD'); a.op('LD')
    a.op('SUB'); a.op('INC'); a.save_drop(SCR_LEN); a.op('DROP')
    a.copy('S'); a.op('RTX')
    b = a.build(); vec[3] = org; code += b; org += len(b)
    # FILE_WRITE ( res lg @tampon fd -- n ) : n = lg si lg > 0, sinon 0
    a = Asm(org)
    a.op('DROP'); a.save_drop(SCR_PTR)
    a.op('DUP'); a.op('CLAMP0'); a.save_drop(SCR_RES)
    a.save_drop(SCR_LEN); a.op('DROP')
    a.copy('W'); a.load(SCR_RES); a.op('RTX')
    b = a.build(); vec[11] = org; code += b; org += len(b)
    return vec, bytes(code)

def main():
    img = open(sys.argv[1], 'rb').read()
    cev = struct.unpack('<Q', img[48:56])[0]
    assert struct.unpack('<Q', img[72:80])[0] == 0 and struct.unpack('<Q', img[80:88])[0] == 0
    out = bytearray(FILE_END - BASE)
    out[0:len(img)] = img
    vec, code = handlers()
    out[HANDLERS - BASE: HANDLERS - BASE + len(code)] = code
    def w64(a, v): out[a - BASE: a - BASE + 8] = struct.pack('<Q', v & (2**64 - 1))
    for n, a in vec.items(): w64(VTB + 8 * n, a)
    if cev: w64(VTB + 8 * 131, cev)                 # le chargeur recopie CEV en VTB[131]
    entry = struct.unpack('<Q', img[24:32])[0]
    b = BOOT
    w64(b + 0, entry); w64(b + 8, DSP0); w64(b + 16, RSP0)
    w64(b + 24, COP0); w64(b + 32, COP0 + 8)        # premier cadre : M64[COP0] := COP0 (banc)
    w64(b + 40, 0); w64(b + 48, LIM_DSP); w64(b + 56, LIM_RSP); w64(b + 64, LIM_CSP)
    w64(b + 72, DSP0)                               # DISPLAY[0] ; les autres à 0
    w64(b + 192, HP0); w64(b + 200, LIM_HP); w64(b + 208, VTB); w64(b + 216, FSCR)
    w64(b + 224, 0xFFFFFFFF)                        # IMASK : tout masqué
    open(sys.argv[2], 'wb').write(out)
    with open(sys.argv[3], 'w') as f:
        f.write(f"BOOT {BOOT:016X}\nCONSOLE {CONSOLE:016X}\nHANDLERS {HANDLERS:016X}\n"
                f"COP0 {COP0:016X}\nMEM_END {MEM_END:016X}\n")
    print(f"handlers : {len(code)} octets ; vecteurs " + ", ".join(f"{n}:{a:X}" for n, a in vec.items())
          + f" ; CEV {cev:X}")
main()
