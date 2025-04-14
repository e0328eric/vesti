os.execute("bibtex ./.vesti-dummy/kindergarten-vol2.aux")
os.execute("makeindex -s ./kindergarten.ist ./.vesti-dummy/kindergarten-vol2.idx")
os.execute("makeindex ./.vesti-dummy/sym.idx")
