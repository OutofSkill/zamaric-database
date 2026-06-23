import os
from sqlalchemy import create_engine, Column, Integer, String, DateTime, inspect, text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from datetime import datetime

Base = declarative_base()

class Note(Base):
    __tablename__ = "noten"

    id = Column(Integer, primary_key = True)
    kategorie = Column(String)
    song = Column(String)
    instrument = Column(String)
    transposition = Column(String, nullable = True)
    level = Column(String, nullable = True)
    dateipfad = Column(String)
    version = Column(DateTime, default = datetime.now)

class Playback(Base):
    __tablename__ = "playbacks"

    id = Column(Integer, primary_key = True)
    kategorie = Column(String)
    song = Column(String)
    typ = Column(String)
    buchstaben = Column(String, nullable = True)
    duration = Column(Integer, nullable = True)
    dateipfad = Column(String)
    version = Column(DateTime, default = datetime.now)

# Datenbank erstellen
basispfad = os.path.dirname(os.path.abspath(__file__))
db_pfad = os.path.join(basispfad, "database.db")
engine = create_engine(f"sqlite:///{db_pfad}")
Base.metadata.create_all(engine)

inspector = inspect(engine)
vorhandene_spalten = [spalte["name"] for spalte in inspector.get_columns("playbacks")]
if "duration" not in vorhandene_spalten:
    with engine.begin() as verbindung:
        verbindung.execute(text("ALTER TABLE playbacks ADD COLUMN duration INTEGER"))

Session = sessionmaker(bind=engine)