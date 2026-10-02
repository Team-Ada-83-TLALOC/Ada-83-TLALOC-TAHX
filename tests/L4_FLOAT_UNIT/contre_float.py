# Contre-vérification de FLOAT_UNIT : arithmétique rationnelle exacte (fractions), arrondi
# au binary64 écrit ici d'après IEEE 754 ; aucun calcul flottant de l'hôte.
import sys
from fractions import Fraction as Q
CANON=0x7FF8000000000000; M64=1<<64
def decode(b):
    s=b>>63; e=(b>>52)&0x7FF; f=b&((1<<52)-1)
    if e==0x7FF: return ('nan' if f else 'inf'), s, None
    v=Q(f,1<<1074) if e==0 else Q((1<<52)|f)*Q(2)**(e-1075)
    return ('zero' if v==0 else 'fin'), s, (-v if s else v)
def rne(n,d):                         # n/d arrondi au plus proche pair (n, d > 0)
    q,r=divmod(n,d)
    if 2*r>d or (2*r==d and q&1): q+=1
    return q
def encode(v, zsign=0):               # rationnel exact -> motif binary64 (RNE)
    if v==0: return zsign<<63
    s=1 if v<0 else 0; a=abs(v)
    e=a.numerator.bit_length()-a.denominator.bit_length()
    if Q(2)**e>a: e-=1                # 2^e <= a < 2^(e+1)
    if e< -1022:                      # sous-normal (ou arrondi vers le plus petit normal)
        m=rne(a.numerator*(1<<1074),a.denominator)
        if m==0: return s<<63
        if m>=1<<52: return (s<<63)|(1<<52)|(m-(1<<52))
        return (s<<63)|m
    sc=Q(2)**(e-52); m=rne((a/sc).numerator,(a/sc).denominator)
    if m==1<<53: m>>=1; e+=1
    if e>1023: return (s<<63)|0x7FF0000000000000
    return (s<<63)|((e+1023)<<52)|(m-(1<<52))
def arith(op,x,y):
    cx,sx,vx=decode(x); cy,sy,vy=decode(y)
    if op==0x21: y^=1<<63; cy,sy,vy=decode(y); op=0x20
    if 'nan' in (cx,cy): return CANON
    if op==0x20:
        if cx=='inf' and cy=='inf': return CANON if sx!=sy else x
        if cx=='inf': return x
        if cy=='inf': return y
        v=vx+vy
        if v==0: return (1<<63) if (cx=='zero' and cy=='zero' and sx and sy) else 0
        return encode(v)
    s=sx^sy
    if op==0x22:
        if (cx=='inf' and cy=='zero') or (cx=='zero' and cy=='inf'): return CANON
        if 'inf' in (cx,cy): return (s<<63)|0x7FF0000000000000
        if 'zero' in (cx,cy): return s<<63
        return encode(vx*vy)
    if op==0x23:
        if (cx=='inf' and cy=='inf') or (cx=='zero' and cy=='zero'): return CANON
        if cx=='inf': return (s<<63)|0x7FF0000000000000
        if cy=='inf' or cx=='zero': return s<<63
        if cy=='zero': return (s<<63)|0x7FF0000000000000
        return encode(vx/vy)
def compare(op,x,y):
    cx,_,vx=decode(x); cy,_,vy=decode(y)
    if 'nan' in (cx,cy): return int(op==0x2B)
    def val(c,v,b): return (Q(10)**400*(-1 if b>>63 else 1)) if c=='inf' else v
    a,b=val(cx,vx,x),val(cy,vy,y)
    return int({0x29:a>b,0x2A:a<b,0x2B:a!=b,0x2C:a==b,0x2D:a>=b,0x2E:a<=b}[op])
def ref(op,S):
    x,y=S
    if op in(0x20,0x21,0x22,0x23): return 0,arith(op,x,y)
    if op==0x28: return 0,x^(1<<63)
    if op==0x2F: return 0,x&~(1<<63)
    if 0x29<=op<=0x2E: return 0,compare(op,x,y)
    if op==0x25:
        i=x-M64 if x>>63 else x
        return 0,encode(Q(i))
    if op in(0x26,0x27):
        c,_,v=decode(x)
        if c in('nan','inf') or not (-(1<<63)<=(v or 0)<(1<<63)): return 130,0
        if c=='zero': return 0,0
        n=abs(v.numerator)//v.denominator; r=abs(v)-n          # partie entière, reste
        if op==0x27 and r>=Q(1,2): n+=1                        # mi-chemin à l'écart de zéro
        n=-n if v<0 else n
        if not -(1<<63)<=n<(1<<63): return 130,0
        return 0,n%M64
    raise ValueError(hex(op))
n=e=0
for l in open(sys.argv[1]):
    if l[0]=='#': continue
    t=l.split(); op=int(t[1],16); S=[int(t[3],16),int(t[4],16)]
    got=(int(t[5],16),int(t[6],16)); exp=ref(op,S); n+=1
    if got!=exp:
        e+=1
        if e<=8: print('ECART',l.strip(),'-> exact',exp[0],hex(exp[1]))
print(n,'instructions,',e,'ecarts')
