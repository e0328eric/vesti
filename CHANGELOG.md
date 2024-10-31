# 0.11.8

# Changed

- In the math context, every math strings has a space at the begin in default. If one remove the
  padding, add `#` at the end of the string literal like `"example"#`.

# 0.11.7

# Added

- Add `--` math token for setminus

# 0.11.5

# Fixed

- Fix a bug for tectonic-backed for inappropriate output for `\today`.

# 0.11.4

# Fixed

- Add a note message for `IOErr`
- Use tectonic 0.15.0

# 0.11.2

## Changed
Fix some bugs

# 0.11.1

## Changed

-   Better error message for tectonic backend

## Fixed

-   a bug not to print notes when backend compilation error occurs
-   `importfile` does not ignore the end of line

# 0.11.0

## Added

-   Add tectonic backend to compile vesti. In this version, it can be installed
    with enabling `tectonic-backed` feature. Here is the command line argument to
    install this feature
    ```console
    $ cargo install vesti --features=tectonic-backed
    ```
-   The new keyword `importfile*` copies the file into `vesti-cache` folder. For instance, if one write
    ```vesti
    importfile* (./foo/bar.txt)
    ```
    then vesti copies `bar.txt` inside in the `./foo` directory into `vesti-cache`.
    Especially, one can write
    ```vesti
    importfile* (@/foo/bar.txt)
    ```
    The special directory `@` refers to the OS specific config directory. For more information about config directory location, see [here](https://docs.rs/dirs/5.0.1/dirs/fn.config_dir.html).

# 0.10.1

## Changed

-   Revert changing behaviors of `\[` and `\]`.

# 0.10.0

## Added

-   Add `makeatletter` and `makeatother` token to make `_` token to be a function
    name alphabet.
-   Add `importltx3`, `ltx3on` and `ltx3off` tokens to use LaTeX3 grammar without
    using the inline LaTeX block.

## Changed

-   Both `\(` and `\)` are now used to write raw `(` and `)` inside of `useenv`
    parameters, respectively.
-   Both `\[` and `\]` are now used to write raw `[` and `]` inside of `useenv`
    parameters or function optional parameters, respectively. **(BREAKING CHANGE)**
-   Function name token should be English alphabets and the token `_`. Previously,
    the additional token was `@` but this is changed. **(BREAKING CHANGE)**

## Note

-   The token `$$` also opens and closes display math environment.
    So use that token instead because of the changing behaviors of `\[` and `\]`.
