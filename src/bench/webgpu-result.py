#!/usr/bin/env python3
"""webgpu-result.py VALUE ERRFILE: bench.sh's extra JSON fields for a WebGPU matmul run.

VALUE is what browser-bench.py printed (GFLOPS, or the page's "error: ..."),
ERRFILE its stderr (the page's detail JSON). Prints the fields without braces:
the adapter, the result's max error, and "error" when there is no GPU number
(no adapter, a wrong result, or a CPU adapter such as SwiftShader).
"""
import json, re, sys

v, err = sys.argv[1], open(sys.argv[2]).read()
m = re.search(r"\{.*\}", err, re.S)
try:
    d = json.loads(m.group(0)) if m else {}
except ValueError:
    d = {}
out = {"adapter": d.get("adapter"), "max_abs_err": d.get("max_abs_err"), "matrix": d.get("N")}
if not re.fullmatch(r"[0-9.]+", v):
    out["error"] = "not available: " + (v.replace("error: ", "WebGPU: ") if v else "no result")
elif re.search(r"swiftshader|llvmpipe|lavapipe|cpu", str(d.get("adapter", "")), re.I):
    out["error"] = "not available: CPU WebGPU adapter only (%s)" % d.get("adapter")
print(json.dumps(out)[1:-1])
