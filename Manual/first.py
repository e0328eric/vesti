import urllib.request
import zipfile
import vesti
import os

vesti_dummy = vesti.getDummyDir()


def downloadFont(fontname, font_url):
    output_path = vesti_dummy + "/font.zip"
    urllib.request.urlretrieve(font_url, output_path)

    print(f"[NOTE]: Downloaded {fontname} into {output_path}")

    with zipfile.ZipFile(output_path, "r") as zf:
        zf.extractall(vesti_dummy)
    if os.path.exists(output_path):
        os.remove(output_path)

    print(f"[NOTE]: Extracted into {vesti_dummy}")


downloadFont(
    "Tex Gyre Pagella", "https://www.fontsquirrel.com/fonts/download/TeX-Gyre-Pagella"
)
downloadFont("STIX Two Math", "https://font.download/dl/font/stix-two-math.zip")
