use std::borrow::Cow;
use std::fmt::Write;

const DEFUN_REDEF: u8 = 1 << 0;
const DEFUN_DECLARE: u8 = 1 << 1;
const DEFUN_PROVIDE: u8 = 1 << 2;
const DEFUN_EXPAND: u8 = 1 << 3;
const DEFUN_GLOBAL: u8 = 1 << 4;
const DEFUN_XPARSE: u8 = 1 << 5;

#[derive(Clone, Copy, Debug)]
pub struct DefunKind {
    pub redef: bool,
    pub declare: bool,
    pub provide: bool,
    pub expand: bool,
    pub global: bool,
    pub xparse: bool,
    pub trim_left: bool,
    pub trim_right: bool,
}

impl Default for DefunKind {
    fn default() -> Self {
        DefunKind {
            redef: false,
            declare: false,
            provide: false,
            expand: false,
            global: false,
            xparse: false,
            trim_left: true,
            trim_right: true,
        }
    }
}

impl DefunKind {
    /// The "type" of this kind: the bitset with the default trim flags masked
    /// off. Equivalent to `DefunKind.takeType`.
    #[inline]
    pub fn take_type(self) -> u8 {
        (u8::from(self.redef) * DEFUN_REDEF)
            | (u8::from(self.declare) * DEFUN_DECLARE)
            | (u8::from(self.provide) * DEFUN_PROVIDE)
            | (u8::from(self.expand) * DEFUN_EXPAND)
            | (u8::from(self.global) * DEFUN_GLOBAL)
            | (u8::from(self.xparse) * DEFUN_XPARSE)
    }

    /// Parse the attribute string. Returns `false` for an invalid combination
    pub fn parse(&mut self, s: &str, is_xparse: bool) -> bool {
        for c in s.chars() {
            match c {
                'r' | 'R' => self.redef = true,
                'p' | 'P' => self.provide = true,
                '!' => self.declare = true,
                'e' | 'E' => self.expand = true,
                'g' | 'G' => self.global = true,
                '<' => self.trim_left = false,
                '>' => self.trim_right = false,
                _ => return false,
            }
        }

        self.xparse = is_xparse;

        let v = self.take_type();
        v == 0
            || v == DEFUN_REDEF
            || v == DEFUN_DECLARE
            || v == DEFUN_REDEF | DEFUN_DECLARE
            || v == DEFUN_EXPAND
            || v == DEFUN_EXPAND | DEFUN_REDEF
            || v == DEFUN_EXPAND | DEFUN_DECLARE
            || v == DEFUN_EXPAND | DEFUN_REDEF | DEFUN_DECLARE
            || v == DEFUN_GLOBAL
            || v == DEFUN_GLOBAL | DEFUN_REDEF
            || v == DEFUN_GLOBAL | DEFUN_DECLARE
            || v == DEFUN_GLOBAL | DEFUN_REDEF | DEFUN_DECLARE
            || v == DEFUN_GLOBAL | DEFUN_EXPAND
            || v == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_REDEF
            || v == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_DECLARE
            || v == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_REDEF | DEFUN_DECLARE
            || v == DEFUN_XPARSE
            || v == DEFUN_XPARSE | DEFUN_REDEF
            || v == DEFUN_XPARSE | DEFUN_PROVIDE
            || v == DEFUN_XPARSE | DEFUN_DECLARE
            || v == DEFUN_XPARSE | DEFUN_EXPAND
            || v == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_REDEF
            || v == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_PROVIDE
            || v == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_DECLARE
    }

    /// Write the definition prologue.
    pub fn prologue(&self, name: &str, w: &mut String) {
        // CHECK_REDEF:
        //   \expandafter\ifx\csname <name>\endcsname\relax
        //   <prefix>\<name>
        // NO_CHECK_REDEF: <prefix>\<name>
        // XPARSE_DEF:     <prefix>{\<name>}
        let check_redef = |w: &mut String, prefix: &str| {
            let _ = write!(
                w,
                "\\expandafter\\ifx\\csname {name}\\endcsname\\relax\n{prefix}\\{name}"
            );
        };
        let no_check_redef = |w: &mut String, prefix: &str| {
            let _ = write!(w, "{prefix}\\{name}");
        };
        let xparse_def = |w: &mut String, cmd: &str| {
            let _ = write!(w, "{cmd}{{\\{name}}}");
        };

        let t = self.take_type();
        if t == 0 {
            check_redef(w, "\\protected\\def");
        } else if t == DEFUN_REDEF {
            no_check_redef(w, "\\protected\\def");
        } else if t == DEFUN_DECLARE {
            check_redef(w, "\\def");
        } else if t == DEFUN_REDEF | DEFUN_DECLARE {
            no_check_redef(w, "\\def");
        } else if t == DEFUN_EXPAND {
            check_redef(w, "\\protected\\edef");
        } else if t == DEFUN_EXPAND | DEFUN_REDEF {
            no_check_redef(w, "\\protected\\edef");
        } else if t == DEFUN_EXPAND | DEFUN_DECLARE {
            check_redef(w, "\\edef");
        } else if t == DEFUN_EXPAND | DEFUN_REDEF | DEFUN_DECLARE {
            no_check_redef(w, "\\edef");
        } else if t == DEFUN_GLOBAL {
            check_redef(w, "\\protected\\gdef");
        } else if t == DEFUN_GLOBAL | DEFUN_REDEF {
            no_check_redef(w, "\\protected\\gdef");
        } else if t == DEFUN_GLOBAL | DEFUN_DECLARE {
            check_redef(w, "\\gdef");
        } else if t == DEFUN_GLOBAL | DEFUN_REDEF | DEFUN_DECLARE {
            no_check_redef(w, "\\gdef");
        } else if t == DEFUN_GLOBAL | DEFUN_EXPAND {
            check_redef(w, "\\protected\\xdef");
        } else if t == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_REDEF {
            no_check_redef(w, "\\protected\\xdef");
        } else if t == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_DECLARE {
            check_redef(w, "\\xdef");
        } else if t == DEFUN_GLOBAL | DEFUN_EXPAND | DEFUN_REDEF | DEFUN_DECLARE {
            no_check_redef(w, "\\xdef");
        } else if t == DEFUN_XPARSE {
            xparse_def(w, "\\NewDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_REDEF {
            xparse_def(w, "\\RenewDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_PROVIDE {
            xparse_def(w, "\\ProvideDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_DECLARE {
            xparse_def(w, "\\DeclareDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_EXPAND {
            xparse_def(w, "\\NewExpandableDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_REDEF {
            xparse_def(w, "\\RenewExpandableDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_PROVIDE {
            xparse_def(w, "\\ProvideExpandableDocumentCommand");
        } else if t == DEFUN_XPARSE | DEFUN_EXPAND | DEFUN_DECLARE {
            xparse_def(w, "\\DeclareExpandableDocumentCommand");
        } else {
            // assume every DefunKind comes from `parse`
            unreachable!("invalid DefunKind type: {t}");
        }
    }

    pub fn param(&self, param_str: Option<&str>, w: &mut String) {
        if self.take_type() & DEFUN_XPARSE == 0 {
            match param_str {
                Some(s) => {
                    let _ = write!(w, "{s}{{");
                }
                None => w.push('{'),
            }
        } else {
            match param_str {
                Some(s) => {
                    let _ = write!(w, "{{{s}}}{{");
                }
                None => w.push_str("{}{"),
            }
        }
    }

    pub fn epilogue(&self, name: &str, w: &mut String) {
        if self.take_type() & DEFUN_REDEF == 0 && self.take_type() & DEFUN_XPARSE == 0 {
            let _ = write!(
                w,
                "}}%\n\\else\\errmessage{{{name} is already defined}}\\fi\n"
            );
        } else {
            w.push_str("}%\n");
        }
    }
}

// Bit layout:
//   bit0 redef, bit1 provide, bit2 declare, then four trim flags (default 1).
const DEFENV_REDEF: u8 = 1 << 0;
const DEFENV_PROVIDE: u8 = 1 << 1;
const DEFENV_DECLARE: u8 = 1 << 2;

#[derive(Clone, Copy, Debug)]
pub struct DefenvKind {
    pub redef: bool,
    pub provide: bool,
    pub declare: bool,
    pub begin_trim_left: bool,
    pub begin_trim_right: bool,
    pub end_trim_left: bool,
    pub end_trim_right: bool,
}

impl Default for DefenvKind {
    fn default() -> Self {
        DefenvKind {
            redef: false,
            provide: false,
            declare: false,
            begin_trim_left: true,
            begin_trim_right: true,
            end_trim_left: true,
            end_trim_right: true,
        }
    }
}

impl DefenvKind {
    #[inline]
    pub fn take_type(self) -> u8 {
        (u8::from(self.redef) * DEFENV_REDEF)
            | (u8::from(self.provide) * DEFENV_PROVIDE)
            | (u8::from(self.declare) * DEFENV_DECLARE)
    }

    pub fn parse(&mut self, s: &str) -> bool {
        for c in s.chars() {
            match c {
                'r' | 'R' => self.redef = true,
                'p' | 'P' => self.provide = true,
                '!' => self.declare = true,
                '<' => self.begin_trim_left = false,
                '>' => self.begin_trim_right = false,
                '(' => self.end_trim_left = false,
                ')' => self.end_trim_right = false,
                _ => return false,
            }
        }

        matches!(
            self.take_type(),
            0 | DEFENV_REDEF | DEFENV_PROVIDE | DEFENV_DECLARE
        )
    }

    pub fn prologue(&self, name: &str, w: &mut String) {
        let xparse_def = |w: &mut String, cmd: &str| {
            let _ = write!(w, "{cmd}{{{name}}}");
        };

        let t = self.take_type();
        if t == 0 {
            xparse_def(w, "\\NewDocumentEnvironment");
        } else if t == DEFENV_REDEF {
            xparse_def(w, "\\RenewDocumentEnvironment");
        } else if t == DEFENV_PROVIDE {
            xparse_def(w, "\\ProvideDocumentEnvironment");
        } else if t == DEFENV_DECLARE {
            xparse_def(w, "\\DeclareDocumentEnvironment");
        } else {
            unreachable!("invalid DefenvKind type: {t}");
        }
    }
}

// Keep the `Cow` import meaningful even if unused in some build configs.
#[allow(dead_code)]
type _Cow<'a> = Cow<'a, str>;
