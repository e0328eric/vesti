local vesti_dummy = vesti.vestiDummyDir()
local stix_two_math_url =
	"https://github.com/stipub/stixfonts/raw/refs/heads/master/fonts/static_ttf/STIXTwoMath-Regular.ttf"

vesti.mkdir(vesti_dummy)
vesti.download(stix_two_math_url, vesti.joinpath(vesti_dummy, "STIXTwoMath-Regular.ttf"))

-- if Vesti.engine_type() != "tect"
--     download_zip_font("Noto Fonts", "https://mirrors.ctan.org/fonts/noto.zip")
-- end
