// Implementing ToString for Statement enum so that making full latex text easily.

use super::ast::*;

impl ToString for Statement {
    fn to_string(&self) -> String {
        match self {
            Statement::DocumentClass { name, options } => docclass_to_string(name, options),
            Statement::Usepackage { name, options } => usepackage_to_string(name, options),
            Statement::MultiUsepackages { pkgs } => multiusepacakge_to_string(pkgs),
            Statement::DocumentStart => String::from("\\begin{document}\n"),
            Statement::DocumentEnd => String::from("\n\\end{document}\n"),
            Statement::MainText(s) => s.clone(),
            Statement::PlainTextInMath(latex) => plaintext_in_math_to_string(latex),
            Statement::Integer(i) => i.to_string(),
            Statement::Float(f) => f.to_string(),
            Statement::RawLatex(s) => s.clone(),
            Statement::MathText { state, text } => math_text_to_string(*state, text),
            Statement::LatexFunction { name, args } => latex_function_to_string(name, args),
            Statement::Environment { name, args, text } => environment_to_string(name, args, text),
            Statement::FunctionDefine {
                name,
                args,
                trim,
                body,
            } => function_def_to_string(name, args, trim, body),
        }
    }
}

fn docclass_to_string(name: &str, options: &Option<Vec<Latex>>) -> String {
    if let Some(opts) = options {
        let mut options_str = String::new();
        for o in opts {
            options_str = options_str + &latex_to_string(o) + ",";
        }
        options_str.pop();

        format!("\\documentclass[{options_str}]{{{name}}}\n")
    } else {
        format!("\\documentclass{{{name}}}\n")
    }
}

fn usepackage_to_string(name: &str, options: &Option<Vec<Latex>>) -> String {
    if let Some(opts) = options {
        let mut options_str = String::new();
        for o in opts {
            options_str = options_str + &latex_to_string(o) + ",";
        }
        options_str.pop();

        format!("\\usepackage[{options_str}]{{{name}}}\n")
    } else {
        format!("\\usepackage{{{name}}}\n")
    }
}

fn multiusepacakge_to_string(pkgs: &[Statement]) -> String {
    let mut output = String::new();
    for pkg in pkgs {
        if let Statement::Usepackage { name, options } = pkg {
            output += &usepackage_to_string(name, options);
        }
    }
    output
}

fn math_text_to_string(state: MathState, text: &[Statement]) -> String {
    let mut output = String::new();
    match state {
        MathState::Text => {
            output += "$";
            for t in text {
                output += &t.to_string();
            }
            output += "$";
        }
        MathState::Inline => {
            output += "\\[";
            for t in text {
                output += &t.to_string();
            }
            output += "\\]";
        }
    }
    output
}

fn plaintext_in_math_to_string(latex: &Latex) -> String {
    let mut output = latex_to_string(latex);
    if output.as_bytes()[output.len() - 1] == b' ' {
        output.pop();
    }

    format!("\\text{{{}}}", output)
}

fn latex_function_to_string(name: &str, args: &Vec<(ArgNeed, Vec<Statement>)>) -> String {
    let mut output = format!("\\{}", name);
    for arg in args {
        let mut tmp = String::new();
        for t in &arg.1 {
            tmp += &t.to_string();
        }
        match arg.0 {
            ArgNeed::MainArg => output = output + "{" + &tmp + "}",
            ArgNeed::Optional => output = output + "[" + &tmp + "]",
            ArgNeed::StarArg => output.push('*'),
        }
    }
    output
}

fn environment_to_string(
    name: &str,
    args: &Vec<(ArgNeed, Vec<Statement>)>,
    text: &Latex,
) -> String {
    let mut output = format!("\\begin{{{name}}}");
    for arg in args {
        let mut tmp = String::new();
        for t in &arg.1 {
            tmp += &t.to_string();
        }
        match arg.0 {
            ArgNeed::MainArg => output = output + "{" + &tmp + "}",
            ArgNeed::Optional => output = output + "[" + &tmp + "]",
            ArgNeed::StarArg => output.push('*'),
        }
    }
    for t in text {
        output += &t.to_string();
    }
    output = output + "\\end{" + name + "}\n";
    output
}

fn latex_to_string(latex: &Latex) -> String {
    let mut output = String::new();
    for l in latex {
        output += &l.to_string();
    }
    output
}

fn function_def_to_string(name: &str, args: &str, trim: &TrimWhitespace, body: &Latex) -> String {
    let mut output = format!("\\def\\{name}{args}{{");

    let mut tmp = String::new();
    for b in body {
        tmp += &b.to_string();
    }

    output += match (trim.start, trim.end) {
        (false, false) => tmp.as_str(),
        (true, false) => tmp.trim_start(),
        (false, true) => tmp.trim_end(),
        (true, true) => tmp.trim(),
    };
    output.push_str("}\n");

    output
}
