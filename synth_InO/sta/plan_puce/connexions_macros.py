import re,sys
from collections import defaultdict,deque
txt=open(sys.argv[1]).read()
a=txt.index("module TAHX_1("); b=txt.index("endmodule",a); top=txt[a:b]
# top ports
hdr=top[:top.index(");")]
ins=set(); outs=set()
for m in re.finditer(r"^\s*(input|output)\s+(.*?);",top,re.M):
    for n in re.split(r",\s*",m.group(2)):
        n=n.strip()
        (ins if m.group(1)=="input" else outs).add(n)
inst=re.finditer(r"^  (\S+) (\\?\S+)\s*\((.*?)\n  \);",top,re.M|re.S)
OUTP={"X","Y","Q","Q_N","L_HI","L_LO"}
macros={}
cells=[]
for m in inst:
    typ,name,body=m.group(1),m.group(2),m.group(3)
    conns=re.findall(r"\.(\\?\S+?)\s*\((.*?)\)\s*,?\s*$",body,re.M)
    conns=[(p.strip(),n.strip()) for p,n in conns]
    if typ.startswith("sg13cmos5l_"):
        cells.append((typ,name,conns))
    else:
        macros[name]=(typ,conns)
short={k:v[0] for k,v in macros.items()}
par={}
def f(x):
    while par.get(x,x)!=x:
        par[x]=par.get(par[x],par[x]); x=par[x]
    return x
for m2 in re.finditer(r"^  assign (\\?\S+(?: \[\d+\])?)\s*=\s*(\\?\S+?)\s*;",top,re.M):
    l,r=m2.group(1).strip(),m2.group(2).strip()
    if "'" in r: continue
    a1,b1=f(l),f(r)
    if a1!=b1: par[a1]=b1
def N(n): return f(n.strip())
cells=[(t_,n_,[(p_,N(x)) for p_,x in c_]) for t_,n_,c_ in cells]
macros={k:(v[0],[(p_,N(x)) for p_,x in v[1]]) for k,v in macros.items()}
ins={N(x) for x in ins}; outs={N(x) for x in outs}
drv={}; loads=defaultdict(list)
for typ,name,conns in cells:
    for p,n in conns:
        if p in OUTP: drv[n]=("cell",name)
        else: loads[n].append(("cell",name))
cellout={name:[n for p,n in conns if p in OUTP] for typ,name,conns in cells}
macro_in=defaultdict(list)
for name,(typ,conns) in macros.items():
    for p,n in conns:
        base=p.lstrip("\\").split("[")[0]; d0=base.split(".")[0]
        if d0.endswith("_o"): drv[n]=("macro",name,base)
        elif base not in("clk_i","reset_i"): loads[n].append(("macro",name,base))
def bus(p): return re.sub(r"\[.*","",p.lstrip("\\"))
cnt=defaultdict(int); detail=defaultdict(lambda:defaultdict(int))
def trace(start,src):
    seen=set([start]); q=deque([(start,0)]); dst=set()
    while q:
        n,d=q.popleft()
        if n in outs: dst.add(("PORT","chip",bus(n)))
        for l in loads[n]:
            if l[0]=="macro": dst.add(("M",short[l[1]],l[2]))
            elif d<8:
                for o in cellout[l[1]]:
                    if o not in seen: seen.add(o); q.append((o,d+1))
    return dst
for name,(typ,conns) in macros.items():
    for p,n in conns:
        base=p.lstrip("\\").split("[")[0]
        if not base.split(".")[0].endswith("_o"): continue
        for k,dm,dp in trace(n,name):
            cnt[(typ,dm)]+=1; detail[(typ,dm)][base+" -> "+dp]+=1
for n in ins:
    if n.startswith("\\") or True:
        nm=n
        if nm in ("CLK_i","RESET_i"): continue
        for k,dm,dp in trace(nm,"chip"):
            cnt[("chip",dm)]+=1; detail[("chip",dm)][bus(nm)+" -> "+dp]+=1
import json
json.dump([[s,sf,d,df,c] for (s,d),dd in detail.items() for k,c in dd.items() for sf,df in [k.split(' -> ')]],open('/tmp/claude-0/fp/liens.json','w'))
for (s,d),c in sorted(cnt.items(),key=lambda x:-x[1]):
    print(f"{s:20} -> {d:20} {c:5}")
print()
for (s,d),dd in sorted(detail.items(),key=lambda x:-sum(x[1].values())):
    print(f"## {s} -> {d}")
    for k,v in sorted(dd.items(),key=lambda x:-x[1])[:12]: print(f"   {v:4} {k}")
