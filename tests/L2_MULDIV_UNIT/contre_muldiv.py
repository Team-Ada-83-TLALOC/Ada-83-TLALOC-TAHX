# Contre-vérification de MULDIV_UNIT : règles V8 en entiers Python non bornés.
import sys
M=1<<64; LO,HI=-(1<<63),(1<<63)-1
def s64(x): x%=M; return x-M if x>=1<<63 else x
def tdiv(n,d):                       # quotient tronqué vers zéro
    q=abs(n)//abs(d); return q if (n<0)==(d<0) else -q
def ref(op,S):
    a,b,c=(s64(x) for x in S)
    if op==0x14:
        p=a*b; return (129,0) if not LO<=p<=HI else (0,p%M)
    if op in(0x15,0x16,0x17):
        if b==0: return 128,0
        q=tdiv(a,b)
        if op==0x15: return (129,0) if q>HI else (0,q%M)
        r=a-b*q                       # signe du dividende
        if op==0x17 and r!=0 and (r<0)!=(b<0): r+=b   # signe du diviseur
        return 0,r%M
    if op in(0x1C,0x1D):
        if c==0: return 128,0
        p=a*b
        if op==0x1C: q=tdiv(p,c)
        else:
            n,d=abs(p),abs(c); q,r=divmod(n,d)
            if 2*r>=d: q+=1
            if (p<0)!=(c<0): q=-q
        return (129,0) if not LO<=q<=HI else (0,q%M)
    raise ValueError(op)
n=e=0
for l in open(sys.argv[1]):
    if l[0]=='#': continue
    t=l.split(); op=int(t[1],16); S=[int(x,16) for x in t[3:6]]
    got=(int(t[6],16),int(t[7],16)); exp=ref(op,S); n+=1
    if got!=exp:
        e+=1
        if e<=5: print('ECART',l.strip(),'-> python',exp)
print(n,'instructions,',e,'ecarts')
