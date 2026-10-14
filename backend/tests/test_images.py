"""Images at their host's largest size (services/images.py), with URL shapes as the sources sent them on 14 Oct (ids made
up), and an artist's photo taken from the copy that has a real one."""
import pytest

from music_backend.models import ArtistRef
from music_backend.services.images import largest
from music_backend.services.matching import to_artist


@pytest.mark.parametrize("url,expected", [
    # JioSaavn: 500 px is its largest
    ("https://c.saavncdn.com/123/Tadipaar-Hindi-2020-150x150.jpg", "https://c.saavncdn.com/123/Tadipaar-Hindi-2020-500x500.jpg"),
    ("https://c.saavncdn.com/artists/MC_Stan_50x50.jpg", "https://c.saavncdn.com/artists/MC_Stan_500x500.jpg"),
    # YouTube Music covers and artist photos
    ("https://lh3.googleusercontent.com/AbC_d-1=w120-h120-l90-rj", "https://lh3.googleusercontent.com/AbC_d-1=w1200-h1200-l90-rj"),
    ("https://lh3.googleusercontent.com/AbC=w544-h544-l90-rj", "https://lh3.googleusercontent.com/AbC=w1200-h1200-l90-rj"),
    # a channel photo: no scheme, 176 px
    ("//yt3.ggpht.com/AbC=s176-c-k-c0x00ffffff-no-rj-mo", "https://yt3.ggpht.com/AbC=s1200-c-k-c0x00ffffff-no-rj-mo"),
    # a video: hq720 is 1280×720 without its cropping query; other names are kept (hq720 is missing for some videos)
    ("https://i.ytimg.com/vi/abc/hq720.jpg?sqp=-oaymwEc&rs=AOn4", "https://i.ytimg.com/vi/abc/hq720.jpg"),
    ("https://i.ytimg.com/vi/abc/hqdefault.jpg?sqp=-oay", "https://i.ytimg.com/vi/abc/hqdefault.jpg?sqp=-oay"),
    # JioSaavn's silhouette for an artist without a photo is no image
    ("https://www.jiosaavn.com/_i/3.0/artist-default-music.png", None),
    (None, None),
    ("", None),
])
def test_an_image_is_asked_for_at_its_hosts_largest_size(url, expected):
    assert largest(url) == expected


def test_largest_changes_nothing_twice():
    url = "https://lh3.googleusercontent.com/AbC=w1200-h1200-l90-rj"
    assert largest(largest(url)) == url


def test_an_artist_shows_the_real_photo_not_jiosaavns_silhouette():
    group = [ArtistRef(source="jiosaavn", id="1", name="MC STAN", image="https://www.jiosaavn.com/_i/3.0/artist-default-music.png"),
             ArtistRef(source="ytmusic", id="UC1", name="MC STAN", image="https://lh3.googleusercontent.com/p=w120-h120-l90-rj")]
    artist = to_artist(group)
    assert artist.best.source == "jiosaavn"                           # JioSaavn's copy still opens the artist page
    assert artist.image == "https://lh3.googleusercontent.com/p=w1200-h1200-l90-rj"
