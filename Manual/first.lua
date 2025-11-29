local f <close> = io.open("font.ves")
if f == nil then
	vesti.getModule("template")
end

vesti.compile("vesti_man.ves", {
	compile_all = true,
})

