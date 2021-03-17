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

        format!("\\documentclass[{0}]{{{1}}}\n", options_str, name)
    } else {
        format!("\\documentclass{{{}}}\n", name)
    }
}

fn usepackage_to_string(name: &str, options: &Option<Vec<Latex>>) -> String {
    if let Some(opts) = options {
        let mut options_str = String::new();
        for o in opts {
            options_str = options_str + &latex_to_string(o) + ",";
        }
        options_str.pop();

        format!("\\usepackage[{0}]{{{1}}}\n", options_str, name)
    } else {
        format!("\\usepackage{{{}}}\n", name)
    }
}

fn multiusepacakge_to_string(pkgs: &Vec<Statement>) -> String {
    let mut output = String::new();
    for pkg in pkgs {
        if let Statement::Usepackage { name, options } = pkg {
            output += &usepackage_to_string(name, options);
        }
    }
    output
}

fn math_text_to_string(state: MathState, text: &Vec<Statement>) -> String {
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
    let mut output = format!("\\begin{{{}}}", name);
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
