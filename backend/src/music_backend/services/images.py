"""Every image the server sends, at the largest size its host serves; the apps ask the host for the size they draw.

The sources hand out small images: JioSaavn's artist photos at 50 px, YouTube Music's at 120 px, channel photos at 176 px
and without "https:", covers at 500-544 px. Each host serves the same image at another size when the URL names it
(measured 14 Oct, #27): JioSaavn up to 500 px (1000 is a 404), Google's hosts (YouTube Music, channel photos) at any
size, a 1200 px copy holding real detail (1.2-1.9× the fine detail of the 544 px one enlarged), YouTube's hq720 at
1280×720 once its cropping query is gone.
"""
import re
from typing import Annotated

from pydantic import AfterValidator

LARGEST = 1200                   # the largest the apps draw: Now Playing, 560 pt on a Retina screen
_GOOGLE = re.compile(r"\.(?:googleusercontent|ggpht)\.com/")
_GOOGLE_WH = re.compile(r"=w\d+-h\d+")
_GOOGLE_S = re.compile(r"=s\d+")
_SAAVN_SIZE = re.compile(r"\d+x\d+(?=\.\w+$)")
# JioSaavn's silhouette for an artist without a photo: no image, so another source's photo is used
_SAAVN_PLACEHOLDER = re.compile(r"jiosaavn\.com/_i/.*default")
_HQ720 = re.compile(r"(/hq720\.jpg)\?.*$")


def largest(url: str | None) -> str | None:
    if not url:
        return None
    if url.startswith("//"):                      # a channel photo: the scheme of the page it came from
        url = "https:" + url
    if _SAAVN_PLACEHOLDER.search(url):
        return None
    if "saavncdn.com/" in url:
        return _SAAVN_SIZE.sub("500x500", url)
    if _GOOGLE.search(url):
        return _GOOGLE_S.sub(f"=s{LARGEST}", _GOOGLE_WH.sub(f"=w{LARGEST}-h{LARGEST}", url))
    return _HQ720.sub(r"\1", url)


# the type of every image field (models.py): what a source returns and what is stored both go out at full size
Image = Annotated[str | None, AfterValidator(largest)]
