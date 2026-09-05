#!/usr/bin/env python3
"""Valida os mods do Lumo contra as regras que a engine Luanti impõe.

Roda em segundos e pega os erros que, de outra forma, só apareceriam como uma
recusa de carregar o jogo inteiro. Uso:  python utils/check_mods.py
"""
import os, sys

def read_conf(path):
    conf = {}
    if not os.path.isfile(path):
        return conf
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        conf[k.strip()] = v.strip()
    return conf

def deps(conf, key):
    return [x.strip() for x in conf.get(key, "").split(",") if x.strip()]

def main():
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = os.path.join(base, "mods")
    mods = {d: read_conf(os.path.join(root, d, "mod.conf"))
            for d in sorted(os.listdir(root))
            if os.path.isfile(os.path.join(root, d, "mod.conf"))}
    game = read_conf(os.path.join(base, "game.conf"))
    first, last = game.get("first_mod"), game.get("last_mod")
    errs = []

    for name, c in mods.items():
        if c.get("name") and c["name"] != name:
            errs.append(f"{name}: mod.conf declara name = {c['name']}")
        for dep in deps(c, "depends"):
            if dep not in mods:
                errs.append(f"{name}: depende de '{dep}', que não existe")

    # src/content/mod_configuration.cpp:252
    if first:
        if first not in mods:
            errs.append(f"first_mod = {first} não existe")
        else:
            d = deps(mods[first], "depends") + deps(mods[first], "optional_depends")
            if d:
                errs.append(f"first_mod '{first}' declara dependências {d}; a engine rejeita o jogo")

    # src/content/mod_configuration.cpp:275
    if last:
        if last not in mods:
            errs.append(f"last_mod = {last} não existe")
        for name, c in mods.items():
            if name != last and last in deps(c, "depends") + deps(c, "optional_depends"):
                errs.append(f"'{name}' depende do last_mod '{last}'; a engine rejeita o jogo")

    def find_cycle(n, seen, stack):
        if n in stack:
            return stack[stack.index(n):] + [n]
        if n in seen or n not in mods:
            return None
        stack.append(n)
        for d in deps(mods[n], "depends"):
            r = find_cycle(d, seen, stack)
            if r:
                return r
        stack.pop(); seen.add(n)
        return None

    seen = set()
    for n in mods:
        c = find_cycle(n, seen, [])
        if c:
            errs.append("ciclo de dependência: " + " -> ".join(c))
            break

    own = [m for m in mods if m.startswith("lumo_")]
    print(f"{len(mods)} mods ({len(mods) - len(own)} herdados, {len(own)} próprios)")
    print(f"first_mod = {first} | last_mod = {last}\n")
    for e in errs:
        print("  ERRO: " + e)
    print("OK: nenhum problema encontrado." if not errs else f"\n{len(errs)} erro(s).")
    return 1 if errs else 0

if __name__ == "__main__":
    sys.exit(main())
