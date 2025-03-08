//! this file specifies the vesti version.
const std = @import("std");

pub const VESTI_VERSION = std.SemanticVersion.parse("0.0.32-beta.20250308") catch unreachable;
