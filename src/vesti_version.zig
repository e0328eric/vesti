//! this file specifies the vesti version.
const std = @import("std");

pub const VESTI_VERSION = std.SemanticVersion.parse("0.0.29-beta.20250216") catch unreachable;
