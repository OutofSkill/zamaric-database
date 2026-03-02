from sqlalchemy import create_engine, Column, Integer, String, DateTime
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from datetime import datetime

Base = declarative_base()

class Note(Base):
    __tablename__ = "noten"
    
    id = Column(Integer, primary_key=True)
    song = Column(String)
    instrument = Column(String)
    stimme = Column(String, nullable=True)  # Nicht alle haben eine Stimme
    dateipfad = Column(String)
    version = Column(DateTime, default=datetime.now)

class Playback(Base):
    __tablename__ = "playbacks"
    
    id = Column(Integer, primary_key=True)
    song = Column(String)
    geschwindigkeit = Column(String)  # "normal" oder "langsam"
    dateipfad = Column(String)
    version = Column(DateTime, default=datetime.now)

# Datenbank erstellen
engine = create_engine("sqlite:///musikapp.db")
Base.metadata.create_all(engine)

Session = sessionmaker(bind=engine)