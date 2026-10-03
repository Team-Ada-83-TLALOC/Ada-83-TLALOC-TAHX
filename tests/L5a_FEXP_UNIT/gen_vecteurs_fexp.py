# Vecteurs de FEXP_UNIT : la boucle de la V8 (FEXP, [Q7], [Q15]) en flottants Python
# (binary64 de l'hôte, arrondi au plus proche pair), avec l'arrêt anticipé exact permis :
# dès que p vaut ±0, ±inf ou NaN, ou que |x| = 1.0, le reste ne change que le signe
# (parité des multiplications restantes par un x négatif). NaN canonique.
#   python3 gen_vecteurs_fexp.py <nombre> <graine> <sortie>
# Ligne : F <x:16> <n:16> <résultat:16>
import struct, random, sys, math
CANON = 0x7FF8000000000000
def f2b(f): return struct.unpack('<Q', struct.pack('<d', f))[0]
def b2f(b): return struct.unpack('<d', struct.pack('<Q', b))[0]
def is_nan_b(b): return (b >> 52) & 0x7FF == 0x7FF and b & ((1 << 52) - 1) != 0
LIMIT = 3000                        # multiplications au plus avant stabilisation (durée du banc)

def full_loop(xb, n):                # la boucle complète, sans arrêt anticipé (contrôle)
    x = b2f(xb); k = abs(n); p = 1.0
    for _ in range(k): p = p * x
    if n < 0:
        if math.isnan(p): r = float('nan')
        elif p == 0.0: r = math.copysign(math.inf, p)
        else: r = 1.0 / p
    else: r = p
    rb = f2b(r)
    return CANON if is_nan_b(rb) or math.isnan(r) else rb

def fexp(xb, n):
    x = b2f(xb)
    neg = n < 0
    k = (-n) if neg else n          # |n|, -2^63 compris
    p = 1.0
    while k > 0:
        if math.isnan(p) or p == 0.0 or math.isinf(p) or abs(x) == 1.0:
            # signe selon la parité restante : le BIT de signe de x (x = -0.0 compte :
            # -0 * -0 = +0 ; en Python, -0.0 < 0 est faux)
            if not math.isnan(p) and math.copysign(1.0, x) < 0 and k % 2 == 1:
                p = -p
            k = 0
            break
        p = p * x
        k -= 1
        if k > 0 and LIMIT and (abs(n) - k) > LIMIT:
            return None             # ne se stabilise pas assez vite : vecteur écarté
    if neg:
        if math.isnan(p): r = float('nan')
        elif p == 0.0: r = math.copysign(math.inf, p)
        else: r = 1.0 / p
    else:
        r = p
    rb = f2b(r)
    return CANON if is_nan_b(rb) or math.isnan(r) else rb

specials = [0.0, -0.0, 1.0, -1.0, 2.0, -2.0, 0.5, -0.5, 3.0, 1.0000001, 0.9999999, -1.0000001,
            math.inf, -math.inf, 5e-324, -5e-324, 1.7976931348623157e308, 1.5, -1.5, 10.0, 0.1]
nans = [0x7FF8000000000000, 0xFFF0000000000001, 0x7FF4000000000123]
def rnd_n(rng):
    u = rng.random()
    if u < 0.1: return rng.choice([0, 1, -1, 2, -2])
    if u < 0.5: return rng.randint(-200, 200)
    if u < 0.75: return rng.randint(-800, 800)
    return rng.choice([2**63 - 1, -2**63, 2**40, -2**40, 2**62 + 1])

def main():
    count, seed, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed); lines = []; kept = 0
    while kept < count:
        u = rng.random()
        if u < 0.45: xb = f2b(rng.choice(specials))
        elif u < 0.5: xb = rng.choice(nans)
        elif u < 0.8: xb = f2b(rng.uniform(-3, 3))
        else: xb = rng.getrandbits(64)
        n = rnd_n(rng)
        r = fexp(xb, n)
        if r is None: continue
        if abs(n) <= 3000:                       # l'arrêt anticipé rend la boucle complète
            assert r == full_loop(xb, n), (hex(xb), n)
        lines.append(f"F {xb:016X} {n & (2**64-1):016X} {r:016X}")
        kept += 1
    with open(out, 'w') as f:
        f.write(f"# FEXP_UNIT : {count} vecteurs, graine {seed}\n" + "\n".join(lines) + "\n")
    print(count, "vecteurs")
main()
