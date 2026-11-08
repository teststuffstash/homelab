"""total / blank / comment / code. bash: comment = first non-space char '#'. python: '#' lines +
every line of a module/class/def docstring (ast). Trailing comments on code lines count as code."""
import ast, sys
def py(p):
    src = open(p).read(); lines = src.split("\n")[:-1] if src.endswith("\n") else src.split("\n")
    doc = set()
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
            b = node.body[0]
            if isinstance(b, ast.Expr) and isinstance(getattr(b, "value", None), ast.Constant) and isinstance(b.value.value, str):
                doc.update(range(b.lineno, b.end_lineno + 1))
    return lines, doc
def count(p):
    if p.endswith(".py"): lines, doc = py(p)
    else: lines = open(p).read().split("\n")[:-1]; doc = set()
    blank = sum(1 for l in lines if not l.strip())
    com = sum(1 for i, l in enumerate(lines, 1) if l.strip() and (l.strip().startswith("#") or i in doc))
    return len(lines), blank, com, len(lines) - blank - com
for p in sys.argv[1:]:
    t, b, c, k = count(p); print(f"{p.split('/')[-1]:28} total {t:4}  blank {b:3}  comment {c:4}  code {k:4}")
