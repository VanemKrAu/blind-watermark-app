"""Generate golden data from numpy legacy RandomState for C++ bit-exact comparison."""
import numpy as np
import sys

out = sys.stdout

def emit(label, values):
    out.write(label.replace(":", " ") + " " + " ".join(format(v, ".17g") for v in values) + "\n")# 1. random_sample sequences
for seed in (1, 42, 999, 7):
    rng = np.random.RandomState(seed)
    emit(f"rand:{seed}", rng.random(10))

# 2. shuffle permutations of [0..n-1]
for seed in (1, 2, 3, 42, 999):
    n = 16
    rng = np.random.RandomState(seed)
    a = list(range(n))
    rng.shuffle(a)
    emit(f"shuf:{seed}:{n}", a)
    n2 = 23
    rng = np.random.RandomState(seed)
    b = list(range(n2))
    rng.shuffle(b)
    emit(f"shuf:{seed}:{n2}", b)

# 3. random_strategy1: random((rows, 16)).argsort(axis=1)
for seed in (1, 42, 999, 7):
    rows = 8
    r = np.random.RandomState(seed).random(size=(rows, 16)).argsort(axis=1)
    for i in range(rows):
        emit(f"strategy1:{seed}:{i}", r[i].tolist())


