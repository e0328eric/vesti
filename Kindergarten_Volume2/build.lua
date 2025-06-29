local err = vesti.setCurrentDir("./.vesti-dummy")
if err ~= nil then
	vesti.printError(err)
	os.exit(1)
end

os.execute("bibtex ./kindergarten-vol2.aux")
os.execute("makeindex -s ../kindergarten.ist ./kindergarten-vol2.idx")
os.execute("makeindex ./sym.idx")

local err = vesti.setCurrentDir("..")
if err ~= nil then
	vesti.printError(err)
	os.exit(1)
end
