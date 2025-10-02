import Pkg
if !haskey(Pkg.dependencies(), "ZipFile")
    Pkg.add("ZipFile")
end

import Downloads
import ZipFile
import .Vesti

vesti_dummy = Vesti.get_dummy_dir()

function download_font(fontname::String, font_url::String)
    output_path = joinpath(vesti_dummy, "$fontname.zip")
    if !ispath(output_path)
        Downloads.download(font_url, output_path)
    end

    archive = ZipFile.Reader(output_path)
    for file in archive.files
        outpath = joinpath(vesti_dummy, file.name)
        mkpath(dirname(outpath))
        write(outpath, read(file))
    end

    println("[NOTE]: Extracted $output_path into $vesti_dummy")
end

mkpath(vesti_dummy)

download_font("Tex Gyre Pagella", "https://www.fontsquirrel.com/fonts/download/TeX-Gyre-Pagella")

if Vesti.engine_type() != "tect"
    download_font("Noto Fonts", "https://mirrors.ctan.org/fonts/noto.zip")
end

download_font("STIX Two Math", "https://font.download/dl/font/stix-two-math.zip")

