"""Exercise Vesti's bundled Tectonic ABI without invoking a GUI error dialog."""
import ctypes
import os
import pathlib
import sys

dll_path, tex_path, output_dir = map(lambda p: str(pathlib.Path(p).resolve()), sys.argv[1:])
os.chdir(output_dir)
dll = ctypes.CDLL(dll_path)
compile_tex = dll.compile_latex_with_tectonic
compile_tex.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_size_t]
compile_tex.restype = ctypes.c_bool
source = tex_path.encode("utf-8")
output = output_dir.encode("utf-8")
sys.exit(0 if compile_tex(source, len(source), output, len(output), 1) else 1)
