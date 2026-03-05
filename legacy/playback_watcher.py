import os
from datetime import datetime, timedelta
import database
import time
import schedule
import unicodedata
from sqlalchemy import func
import threading

# Pfad zum Ordner mit allen Musiknoten + Playbacks
basispfad = r"C:\Users\phil_\Documents\musikapp\Backend\stuecke"

# Uhrzeit an der die DB aktualisiert wird
aktualisierungszeit = "03:00"

def log(tag, message):
    timestamp = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    print(f"[{timestamp}] {tag} {message}")

"""
Parst einen Dateinamen und extrahiert Song und Geschwindigkeit.

Input:  dateiname (str) - z.B. "apt_normal.mp3"
Output: attributes = [Song, Geschwindigkeit]
        Bei fehlendem Wert wird None zurueckgegeben
"""
def parse_atrributes(dateiname):

    # Nach MP3-Dateien filtern
    if dateiname.endswith(".mp3"):
        
        # Dateinamen korrekt formatieren 
        playbackname = dateiname.removesuffix(".mp3")
        playbackname = playbackname.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
        playbackname = playbackname.replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue")
        playbackname = unicodedata.normalize("NFD", playbackname).encode("ascii", "ignore").decode("utf-8")

        # String zwischen "_" aufteilen
        attributes = playbackname.split("_")

        # Name des Playbacks aus dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            log("[ERROR]:", "No song name found")
            song = None

        # Geschwindigkeit aus dem Dateinamen filtern
        try:
            geschwindigkeit = attributes[1]
        except:
            log("[ERROR]:", f"No speed found in {attributes[0]}")
            geschwindigkeit = None

        if song is None or geschwindigkeit is None:
            return None

        return song, geschwindigkeit

"""
Ueberprueft die Dateipfade aus der Database. Wenn Datei auf Pfad nicht mehr existiert
wird der Eintrag aus der DB geloescht.

Input:  None
Output: Anzahl geloeschter Eintraege (int)
"""
def clean_database():
    # DB Session oeffnen
    session = database.Session()

    # Alle Playbacks aus der DB auflisten
    alle_playbacks = session.query(database.Playback).all()

    # Zaehler fuer geloeschte Eintraege
    geloescht = 0

    # Ueber DB Eintraege iterieren
    for playback in alle_playbacks:
        if not os.path.exists(playback.dateipfad):
            log("[REMOVED]", f"{playback.song} - {playback.geschwindigkeit}")
            session.delete(playback)
            geloescht += 1
    
    session.commit()
    session.close()

    return geloescht

"""
Extrahiert die gefragten Attribute und fuellt die Datenbank mit diesen.

Input:  pfad (str) - Uebergeordneter Pfad der Songs
Output: Anzahl der Aenderungen (int)
"""
def fill_database(pfad):
    # Liste mit allen Directories im Ordner
    dateien = os.listdir(pfad)

    # DB Session oeffnen 
    session = database.Session()

    # Zaehler fuer Aenderungen
    aenderungen = 0

    # Ueber Unterordner iterieren
    for ordner in dateien:

        # Unterordner oeffnen + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        if not os.path.isdir(unterordnerPfad):
            continue
        dateienUnterodner = os.listdir(unterordnerPfad)

        # Ueber Dateien im Unterordner iterieren
        for note in dateienUnterodner:
            
            # Wir suchen den Playbacks Ordner
            if note.lower() == "playbacks":

                # Playbacks-Ordner oeffnen + Liste mit Dateien erstellen
                playbacksPath = os.path.join(unterordnerPfad, note)
                playbacks = os.listdir(playbacksPath)

                for playback in playbacks:
            
                    # Song und Geschwindigkeit aus Dateinamen auslesen
                    result = parse_atrributes(playback)

                    # Wenn Datei eine MP3
                    if result is not None:
                        song, geschwindigkeit = result

                        # Pfad zum Playback
                        dateipfad = os.path.join(playbacksPath, playback)

                        # Letztes Aenderungsdatum ermitteln
                        timestamp = os.path.getmtime(dateipfad)
                        version = datetime.fromtimestamp(timestamp)

                        # Ist None wenn das Playback noch nicht in der DB existiert
                        existierende_playback = session.query(database.Playback).filter(
                            func.lower(database.Playback.song) == song.lower(),
                            func.lower(database.Playback.geschwindigkeit) == geschwindigkeit.lower(),
                        ).first()

                        # Falls das Playback noch nicht existiert neues Playback erstellen
                        if existierende_playback is None:

                            # Neues Objekt in der DB erstellen
                            neue_playback = database.Playback(
                                song = song,
                                geschwindigkeit = geschwindigkeit,
                                dateipfad = dateipfad,
                                version = version
                            )

                            log("[ADDED]", f"{song} - {geschwindigkeit}")
                            session.add(neue_playback)
                            aenderungen += 1

                        # Sonst version vergleichen und updaten falls neuer
                        else:
                            if version > existierende_playback.version:
                                log("[UPDATED]", f"{song} - {geschwindigkeit}")
                                existierende_playback.version = version
                                aenderungen += 1

    # Alle neuen Objekte in der DB speichern
    session.commit()
    session.close()

    return aenderungen

def job():
    geloescht = clean_database()
    aenderungen = fill_database(basispfad)

    if geloescht + aenderungen == 0:
        log("[INFO]", "No changes found")

    naechster_durchlauf = datetime.now().replace(hour=3, minute=0, second=0, microsecond=0)
    if naechster_durchlauf < datetime.now():
        naechster_durchlauf += timedelta(days=1)

    log("[DONE]", f"Cycle completed - Next automated cycle at {naechster_durchlauf.strftime("%d.%m.%Y %H:%M")}")

stop_event = threading.Event()

def listen_for_commands():
    while True:
        command = input("playback_watcher > ")
        if command == "cycle":
            job()
        elif command == "fill":
            fill_database(basispfad)
            log("[DONE]", "Database filled")
        elif command == "clean":
            clean_database()
            log("[DONE]", "Database cleaned")
        elif command == "clear":
            session = database.Session()
            alle_playbacks = session.query(database.Playback).all()
            for playback in alle_playbacks:
                log("[REMOVED]", f"{playback.song} - {playback.geschwindigkeit}")
            session.query(database.Playback).delete()
            session.commit()
            session.close()
            log("[DONE]", "Database cleared")
        elif command == "quit":
            log("[INFO]", "Shutting down...")
            stop_event.set()
            return

def main():
    # Jeden Tag um 03:00 Uhr
    schedule.every().day.at(aktualisierungszeit).do(job)

    # Terminal-Listener in separatem Thread starten
    thread = threading.Thread(target=listen_for_commands, daemon=True)
    thread.start()

    while not stop_event.is_set():
        schedule.run_pending()
        time.sleep(1)

if __name__ == "__main__":
    main()