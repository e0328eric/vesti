import os
import subprocess as sp
import vesti

if vesti.engineType() != "tect":
    print("Run bibtex and makeindex")
    os.chdir("./.vesti-dummy")
    sp.run(["bibtex", "./kindergarten-vol2.aux"])
    sp.run(["makeindex", "-s", "../kindergarten.ist", "./kindergarten-vol2.idx"])
    sp.run(["makeindex", "./sym.idx"])
    os.chdir("..")
