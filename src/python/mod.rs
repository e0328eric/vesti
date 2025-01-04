use std::ffi::CString;

use pyo3::ffi::c_str;
use pyo3::prelude::*;
use pyo3::types::{PyDict, PyString};

use crate::error::{self, VestiErr, VestiParseErrKind};
use crate::location::Span;

pub struct PythonVm {
    source: CString,
    pycode_span: Span,
}

impl PythonVm {
    pub fn new(source: String, pycode_span: Span) -> error::Result<Self> {
        Ok(Self {
            source: CString::new(source).map_err(|_| VestiErr::ParseErr {
                err_kind: VestiParseErrKind::PythonEvalErr {
                    msg: String::from("null byte was found inside of the pycode"),
                },
                location: pycode_span,
            })?,
            pycode_span,
        })
    }

    pub fn run(&self) -> error::Result<String> {
        Python::with_gil(|py| {
            let globals = PyDict::new(py);
            let vesti_mod = import_vesti_py_module(py).map_err(|err| VestiErr::ParseErr {
                err_kind: VestiParseErrKind::PythonEvalErr {
                    msg: err.value(py).to_string(),
                },
                location: self.pycode_span,
            })?;
            vesti_mod
                .add("__vesti_output_str__", "")
                .map_err(|err| VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::PythonEvalErr {
                        msg: err.value(py).to_string(),
                    },
                    location: self.pycode_span,
                })?;

            py.run(self.source.as_c_str(), Some(&globals), None)
                .map_err(|err| VestiErr::ParseErr {
                    err_kind: VestiParseErrKind::PythonEvalErr {
                        msg: err.value(py).to_string(),
                    },
                    location: self.pycode_span,
                })?;

            let vesti_output_str =
                vesti_mod
                    .getattr("__vesti_output_str__")
                    .map_err(|err| VestiErr::ParseErr {
                        err_kind: VestiParseErrKind::PythonEvalErr {
                            msg: err.value(py).to_string(),
                        },
                        location: self.pycode_span,
                    })?;
            let vesti_output_str =
                vesti_output_str
                    .downcast::<PyString>()
                    .map_err(|err| VestiErr::ParseErr {
                        err_kind: VestiParseErrKind::PythonEvalErr {
                            msg: format!("|{err}|"),
                        },
                        location: self.pycode_span,
                    })?;

            Ok(vesti_output_str.to_string_lossy().into_owned())
        })
    }
}

#[inline]
fn import_vesti_py_module(py: Python<'_>) -> PyResult<Bound<'_, PyModule>> {
    PyModule::from_code(
        py,
        c_str!(include_str!("./vesti.py")),
        c"vesti.py",
        c"vesti",
    )
}
