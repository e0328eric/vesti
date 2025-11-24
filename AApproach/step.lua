if vesti.engineType() ~= "tect" then
    local cwd = vesti.getCurrentDir()
    vesti.setCurrentDir(vesti.vestiDummyDir())
    os.execute("bibtex aapproach")
    vesti.setCurrentDir(cwd)
end
