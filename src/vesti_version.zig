//! this file specifies the vesti version.
const std = @import("std");

pub const VESTI_VERSION = std.SemanticVersion.parse("0.16.0-beta.20250215") catch unreachable;
