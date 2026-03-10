from fastapi import FastAPI
from fastapi.responses import FileResponse
import database
import json

app = FastAPI()

@app.get("/noten")
def get_noten():
    session = database.Session()
    alle_noten = session.query(database.Note).all()
    session.close

    return [{"id": note.id, "song": note.song, "instrument": note.instrument, "transposition": note.transposition, "stimme": note.level} for note in alle_noten]

@app.get("/playbacks")
def get_playbacks():
    session = database.Session()
    alle_playbacks = session.query(database.Playback).all()
    session.close()

    return [{"id": playback.id, "song": playback.song, "typ": playback.typ, "buchstaben": json.loads(playback.buchstaben) if playback.buchstaben else None} for playback in alle_playbacks]

@app.get("/noten/{id}/pdf")
def get_pdf(id : int):
    session = database.Session()
    note = session.query(database.Note).filter(database.Note.id == id).first()
    session.close()

    return FileResponse(note.dateipfad)

@app.get("/playbacks/{id}/audio")
def get_mp3(id : int):
    session = database.Session()
    playback = session.query(database.Playback).filter(database.Playback.id == id).first()
    session.close()

    return FileResponse(playback.dateipfad)