from typing import Literal
from pydantic import BaseModel

class Listing(BaseModel):
    source : Literal["jiosaavn", "ytmusic", "youtube"]
    id : str
    title : str
    artists : list[str]
    album: str | None
    duration: int
    popularity : int | None
