local function download_if_missing(url, dest)
    local f <close> = io.open(dest, "r")
    if not f then
        vesti.download(url, dest)
    end
end

local vesti_dummy = vesti.vestiDummyDir()
vesti.mkdir(vesti_dummy)

local stix2_fonts_prefix = "https://mirrors.ctan.org/fonts/stix2-otf/"
local overlock_fonts_prefix = "https://mirrors.ctan.org/fonts/overlock/opentype/"

local stix2_fonts = {
    "STIXTwoText-Regular.otf",
    "STIXTwoText-Bold.otf",
    "STIXTwoText-Italic.otf",
    "STIXTwoMath-Regular.otf",
}
local overlock_fonts = {
    "Overlock-Regular-OTF.otf",
    "Overlock-Bold-OTF.otf",
    "Overlock-Italic-OTF.otf",
}

for _, font in ipairs(stix2_fonts) do
    download_if_missing(stix2_fonts_prefix .. font, vesti.joinpath(vesti_dummy, font))
end
for _, font in ipairs(overlock_fonts) do
    download_if_missing(overlock_fonts_prefix .. font, vesti.joinpath(vesti_dummy, font))
end
