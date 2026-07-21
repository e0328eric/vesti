local f <close> = io.open("font.ves")
if f == nil then
	vesti.getModule("template")
end

vesti.compile("aapproach.ves", {
	engine = "tect",
	compile_all = true,
})
