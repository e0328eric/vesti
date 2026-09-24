-- Test-only exporter: exercise the real CLI, parser, and code generator.
-- The CLI's emit_tex flag is currently a no-op, so exit after vesti.parse.
local input = assert(os.getenv("VESTI_TABLE_INPUT"))
local output = assert(os.getenv("VESTI_TABLE_OUTPUT"))
local file = assert(io.open(input, "rb"))
local source = file:read("a")
file:close()
local plain = os.getenv("VESTI_TABLE_PLAIN") == "1"
if plain then
  -- Remove only known document wrappers in our fixtures. Cell grammar is
  -- parsed unchanged by Vesti; never split or scan table/content braces here.
  source = source:gsub("^docclass[^\r\n]*[\r\n]+", "")
  source = source:gsub("^startdoc[\r\n]+", "")
  source = source:gsub("\\section%b{}", "")
end
local tex = vesti.parse(source)
file = assert(io.open(output, "wb"))
if plain then
  assert(not tex:find("\\usepackage", 1, true), "plain specimen imported a package")
  file:write("\\hsize=400pt\\vsize=700pt\\nopagenumbers\n")
end
file:write(tex)
if plain then file:write("\n\\bye\n") end
file:close()
os.exit(0, true)
