# vesti

A toy project which is a preprocessor that is compiled to latex code
This program is in beta, so do not use this program in real projects, yet.

# TODO to upgrade to v0.2.0
- [x] Well-orgarized error module. (current version is somewhat bad)

# TODO to upgrade to v0.3.0
- [x] Fix memory leaking when vesti is closed with error. (in the current version, it uses process::exit to exit the program)

# TODO to upgrade to v0.4.0
- [ ] Implement tree-sitter parser for vesti.
- [ ] Use [tectonic](https://tectonic-typesetting.github.io/en-US/) typesetting system with the backend of the vesti
	  so that vesti can be used in standalone. (without using latex compiler to generate the final pdf file)
- [ ] Make `classimpl` and `pkgimpl` keywords that indicates the current vesti file will be compiled into
	  `.cls` and `.sty` files, respectively.
- [ ] Make `vesti-cache` directory that contains all `tex` related files so that vesti main project location looks like cleaner.
- [ ] Add `--emit` and `-e` flag that acts as same as the previous version of vesti.
