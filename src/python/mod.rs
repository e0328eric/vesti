use rustpython::InterpreterConfig;
use rustpython_vm::builtins::PyStr;
use rustpython_vm::convert::ToPyObject;
use rustpython_vm::scope::Scope;
use rustpython_vm::{pymodule, Interpreter};

use crate::error::{self, VestiErr, VestiParseErrKind};
use crate::location::Span;

pub struct Python<'s> {
    source: &'s str,
    interpreter: Interpreter,
    pycode_span: Span,
}

impl<'s> Python<'s> {
    pub fn new(source: &'s str, pycode_span: Span) -> Self {
        let interpreter = InterpreterConfig::new()
            .init_stdlib()
            .init_hook(Box::new(|vm| {
                vm.add_native_module("vesti".to_owned(), Box::new(vesti::make_module));
            }))
            .interpreter();

        Self {
            source,
            interpreter,
            pycode_span,
        }
    }

    pub fn run(&self) -> error::Result<String> {
        // TODO: for now, output values are ignored
        self.interpreter.enter(|vm| {
            let scope = {
                let globals = vm.ctx.new_dict();
                if !globals.contains_key("__builtins__", vm) {
                    globals
                        .set_item("__builtins__", vm.builtins.clone().into(), vm)
                        .unwrap();
                }
                if !globals.contains_key("__vesti_output_str__", vm) {
                    globals
                        .set_item("__vesti_output_str__", "".to_pyobject(vm), vm)
                        .unwrap();
                }
                Scope::new(None, globals)
            };
            vm.run_block_expr(scope.clone(), self.source)
                .map_err(|err| {
                    // TODO: bake this error message into VestiErr
                    vm.print_exception(err);
                    VestiErr::ParseErr {
                        err_kind: VestiParseErrKind::PythonEvalErr {
                            note_msg: "failed to evaluate pycode".to_string(),
                        },
                        location: self.pycode_span,
                    }
                })
                .and_then(|_| {
                    scope
                        .globals
                        .get_item("__vesti_output_str__", vm)
                        .ok()
                        .and_then(|global| global.downcast::<PyStr>().ok())
                        .map(|s| s.as_str().to_string())
                        .ok_or(VestiErr::ParseErr {
                            err_kind: VestiParseErrKind::PythonEvalErr {
                                note_msg: "cannot obtain __vesti_output_str__ value".to_string(),
                            },
                            location: self.pycode_span,
                        })
                })
        })
    }
}

// vesti python module implementation
#[pymodule]
mod vesti {
    use rustpython_vm::builtins::{PyStr, PyStrRef};
    use rustpython_vm::convert::ToPyObject;
    use rustpython_vm::VirtualMachine;

    #[pyfunction]
    fn sprint(s: PyStrRef, vm: &VirtualMachine) {
        let mut vesti_output_str = String::with_capacity(50);
        let vesti_output_str_py = vm
            .current_globals()
            .get_item("__vesti_output_str__", vm)
            .expect("failed to read __vesti_output_str__")
            .downcast::<PyStr>()
            .expect("failed to read __vesti_output_str__");
        vesti_output_str.push_str(vesti_output_str_py.as_str());
        vesti_output_str.push_str(s.as_str());

        vm.current_globals()
            .set_item("__vesti_output_str__", vesti_output_str.to_pyobject(vm), vm)
            .expect("failed to write __vesti_output_str__");
    }

    #[pyfunction]
    fn sprintn(s: PyStrRef, vm: &VirtualMachine) {
        let mut vesti_output_str = String::with_capacity(50);
        let vesti_output_str_py = vm
            .current_globals()
            .get_item("__vesti_output_str__", vm)
            .expect("failed to read __vesti_output_str__")
            .downcast::<PyStr>()
            .expect("failed to read __vesti_output_str__");
        vesti_output_str.push_str(vesti_output_str_py.as_str());
        vesti_output_str.push_str(s.as_str());
        vesti_output_str.push('\n');

        vm.current_globals()
            .set_item("__vesti_output_str__", vesti_output_str.to_pyobject(vm), vm)
            .expect("failed to write __vesti_output_str__");
    }

    #[pyfunction]
    fn sprintln(s: PyStrRef, vm: &VirtualMachine) {
        let mut vesti_output_str = String::with_capacity(50);
        let vesti_output_str_py = vm
            .current_globals()
            .get_item("__vesti_output_str__", vm)
            .expect("failed to read __vesti_output_str__")
            .downcast::<PyStr>()
            .expect("failed to read __vesti_output_str__");
        vesti_output_str.push_str(vesti_output_str_py.as_str());
        vesti_output_str.push_str(s.as_str());
        vesti_output_str.push_str("\n\n");

        vm.current_globals()
            .set_item("__vesti_output_str__", vesti_output_str.to_pyobject(vm), vm)
            .expect("failed to write __vesti_output_str__");
    }
}
