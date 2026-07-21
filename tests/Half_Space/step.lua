if vesti.getEngineType() ~= "tect" then
    local cwd = vesti.getCurrentDir()
    vesti.setCurrentDir(vesti.vestiDummyDir())
    os.execute("bibtex half_space")
    vesti.setCurrentDir(cwd)
end

