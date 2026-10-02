# Contre-vérification d'INTEGER_UNIT : d'après l'en-tête de L1_INTEGER_UNIT.vhd, en entiers
# Python non bornés (aucune expression partagée avec Machine ni avec le générateur).
import sys
M=1<<64
def s64(x): x%=M; return x-M if x>=1<<63 else x
def u64(x): return x%M
def s32(v): v&=0xFFFFFFFF; return v-(1<<32) if v>>31 else v
def ref(op,lvl,ofs,val,ak,addr,n,S):
    a,b=S[0],S[1]
    if op==0x00: return 0,a&b
    if op==0x01: return 0,a|b
    if op==0x02: return 0,a^b
    if op==0x03: return 0,u64(~a)
    if op in(4,5,6):
        if b>=64: return 137,0
        if op==4: return 0,u64(a<<b)
        if op==5: return 0,a>>b
        return 0,u64(s64(a)>>b)
    if op==7: return 0,(0 if s64(a)<0 else a)
    if op in(8,0x0F,0x10,0x12,0x11,0x13):
        x=s64(a); y=s64(b)
        r={8:-x,0x0F:abs(x),0x10:x+y,0x12:x-y,0x11:x+1,0x13:x-1}[op]
        if not -(1<<63)<=r<(1<<63): return 129,0
        return 0,u64(r)
    if op in(9,0xA,0xB,0xC,0xD,0xE):
        x,y=s64(a),s64(b)
        return 0,int({9:x>y,0xA:x<y,0xB:x!=y,0xC:x==y,0xD:x>=y,0xE:x<=y}[op])
    if op in(0x18,0x19,0x1A,0xC4,0xC5,0xC6):
        if op in(0x18,0x19): l,w=S[1],S[2]
        elif op==0x1A: l,w=S[2],S[3]
        else: l,w=val,ofs
        if w==0 or w>64 or l+w>64: return 137,0     # entiers non bornés : pas d'enveloppe
        f=(a>>l)&((1<<w)-1)
        if op in(0x18,0xC4): return 0,f
        if op in(0x19,0xC5): return 0,u64(f-(1<<w) if f>>(w-1) else f)
        m=((1<<w)-1)<<l
        return 0,(a & ~m & (M-1)) | ((b<<l)&m)
    if op in(0x47,0x4B): return 0,(addr if ak else u64(a+s32(val)))
    if op in(0xC0,0xC1,0xC2) or 0xD0<=op<=0xDF: return 0,u64(s32(val))
    if op==0xC7: return 0,((val&0xFFFFFFFF)<<32)|(a&0xFFFFFFFF)
    raise ValueError(hex(op))
n=e=0
for l in open(sys.argv[1]):
    if l.startswith('#'): continue
    t=l.split()
    op,lvl,ofs,val=int(t[1],16),int(t[2],16),int(t[3],16),int(t[4],16)
    ak=t[5]=='1'; addr=int(t[6],16); ns=int(t[7]); S=[int(x,16) for x in t[8:12]]
    f,r=int(t[12],16),int(t[13],16)
    fr,rr=ref(op,lvl,ofs,val,ak,addr,ns,S)
    exp=(fr, rr if fr==0 else 0)
    n+=1
    if (f,r)!=exp:
        e+=1
        if e<=5: print('ECART',l.strip(),'-> python',hex(exp[0]),hex(exp[1]))
print(n,'instructions,',e,'ecarts')
