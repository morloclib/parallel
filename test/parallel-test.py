import numpy as np

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RESET='\033[0m'

# Flatten a vector to a row-major list of elements. Used in tests to compare
# vectors with expected values regardless of the wire form.
def flatten_vector(v):
    return list(np.asarray(v).flatten())

def good(msg):
    return f"{GREEN}{msg}{RESET}"

def bad(msg):
    return f"{RED}{msg}{RESET}"

def info(msg):
    return f"{BLUE}{msg}{RESET}"

# Structural equality that handles numpy arrays at any nesting depth.
# Plain `==` between a tuple and a tuple-containing-ndarray raises
# "truth value of an array is ambiguous" because tuple equality reduces
# element-wise comparisons to bool, and `ndarray == ndarray` returns
# an ndarray. Walk both values in lockstep, deferring to np.allclose
# for numeric ndarrays (shape match + element-wise float tolerance) and
# recursing element-by-element for object-dtype ndarrays (since
# np.allclose internally calls np.isfinite, which rejects dtype=object).
def _deep_equal(x, y):
    if isinstance(x, np.ndarray) or isinstance(y, np.ndarray):
        xa = np.asarray(x)
        ya = np.asarray(y)
        if xa.shape != ya.shape:
            return False
        # Boxed (dtype=object) arrays hold arbitrary Python objects --
        # BigInt, strings, nested types -- which numeric ufuncs reject.
        # Use element-wise structural comparison so a Vector of BigInts
        # / Strings / records is comparable.
        if xa.dtype == object or ya.dtype == object:
            return all(_deep_equal(xa.flat[i], ya.flat[i]) for i in range(xa.size))
        return bool(np.allclose(xa, ya))
    if isinstance(x, (tuple, list)) and isinstance(y, (tuple, list)):
        if len(x) != len(y):
            return False
        return all(_deep_equal(a, b) for a, b in zip(x, y))
    if isinstance(x, dict) and isinstance(y, dict):
        if x.keys() != y.keys():
            return False
        return all(_deep_equal(x[k], y[k]) for k in x)
    return x == y

def testEqual(msg, x, y, results):
    (nfails, ntests) = results
    equal = _deep_equal(x, y)
    if equal:
        print(f"  {msg} ... {good('PASS')}")
        return (nfails, ntests + 1)
    else:
        print(f"  {msg} ... {bad('FAIL')}")
        print(f"    expected: {y}")
        print(f"    got:      {x}")
        return (nfails + 1, ntests + 1)

def testTrue(msg, is_true, results):
    (nfails, ntests) = results
    if is_true:
        print(f"  {msg} ... {good('PASS')}")
        return (nfails, ntests + 1)
    else:
        print(f"  {msg} ... {bad('FAIL')}")
        return (nfails + 1, ntests + 1)

def printMsg(msg, x):
    print(info(msg))
    return x

def printResult(x):
    if(x[0] == 0):
        print(good(f"All {x[1]!s} tests pass"))
    else:
        print(bad(f"{x[0]!s}/{x[1]!s} tests failed"))
    return x
