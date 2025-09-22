module Vesti

export print, parse, get_dummy_dir, engine_type

function print(args...; sep::AbstractString=" ", nl::Integer=1)
    av = Any[args...]
    ccall(:vesti_print, Cvoid, (Any, Cstring, Cuint), av, sep, UInt32(clamp(nl,0,2)))
    nothing
end

parse(s::AbstractString)::String = ccall(:vesti_parse, Any, (Any,), String(s))
get_dummy_dir()::String = ccall(:vesti_get_dummy_dir, Any, ())
engine_type()::String = ccall(:vesti_engine_type, Any, ())
function download_module(mod::AbstractString)
    ccall(:vesti_download_module, Cvoid, (Cstring,), mod)
    nothing
end

end
