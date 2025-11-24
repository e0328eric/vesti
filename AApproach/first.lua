local f <close> = io.open("font.ves")
if f == nil then
	vesti.getModule("template")
end

vesti.compile("aapproach.ves", {
	compile_all = true,
})
