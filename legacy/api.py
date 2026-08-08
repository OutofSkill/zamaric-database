from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
import database
import json
import os

app = FastAPI()

@app.get("/noten")
def get_noten():
    session = database.Session()
    alle_noten = session.query(database.Note).all()
    session.close();

    return [{"id": note.id, "kategorie": note.kategorie, "song": note.song, "instrument": note.instrument, "transposition": note.transposition, "level": note.level, "version": str(note.version)} for note in alle_noten]

@app.get("/playbacks")
def get_playbacks():
    session = database.Session()
    alle_playbacks = session.query(database.Playback).all()
    session.close()

    return [{"id": playback.id, "kategorie": playback.kategorie, "song": playback.song, "typ": playback.typ, "buchstaben": json.loads(playback.buchstaben) if playback.buchstaben else None, "duration": playback.duration, "version": str(playback.version)} for playback in alle_playbacks]

@app.get("/noten/{id}/pdf")
def get_pdf(id : int):
    session = database.Session()
    note = session.query(database.Note).filter(database.Note.id == id).first()
    session.close()

    if note is None or not note.dateipfad or not os.path.isfile(note.dateipfad):
        raise HTTPException(status_code=404)

    return FileResponse(note.dateipfad)

@app.get("/playbacks/{id}/audio")
def get_mp3(id : int):
    session = database.Session()
    playback = session.query(database.Playback).filter(database.Playback.id == id).first()
    session.close()

    if playback is None or not playback.dateipfad or not os.path.isfile(playback.dateipfad):
        raise HTTPException(status_code=404)

    return FileResponse(playback.dateipfad)