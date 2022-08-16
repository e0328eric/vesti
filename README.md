# vesti

A toy project which is a preprocessor that is compiled to latex code
This program is in beta, so do not use this program in real projects, yet.

# TODO to upgrade to v0.2.0
- [x] well-orgarized error module (current version is somewhat bad)

# TODO to upgrade to v0.3.0
- [ ] fix memory leaking when vesti is closed with error (in the current version, it uses process::exit to exit the program)
- [ ] make `xdefenv` and `xredefenv` to make a new environment using `xparse` LaTeX package
