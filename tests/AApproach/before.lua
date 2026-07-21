local function download_if_missing(url, dest)
    local f <close> = io.open(dest, "r")
    if not f then
        vesti.download(url, dest)
    end
end

local vesti_dummy = vesti.vestiDummyDir()
vesti.mkdir(vesti_dummy)

local fonts_prefix = "https://mirrors.ctan.org/fonts/stix2-otf/"

local fonts = {
    "STIXTwoText-Regular.otf",
    "STIXTwoText-Bold.otf",
    "STIXTwoText-Italic.otf",
    "STIXTwoMath-Regular.otf",
}

for _, font in ipairs(fonts) do
    download_if_missing(fonts_prefix .. font, vesti.joinpath(vesti_dummy, font))
end
