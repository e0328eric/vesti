if Vesti.engine_type() != "tect"
    cd("./.vesti-dummy") do
        run("bibtex ./aapproach.aux")
    end
end
