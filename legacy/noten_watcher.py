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
Parst einen Dateinamen und extrahiert Song, Instrument und Stimme.

Input:  dateiname (str) - z.B. "apt_trompete_1.pdf"
Output: attributes = [Song, Instrument, Stimme]
        Bei fehlendem Wert wird None zurueckgegeben
"""
def parse_atrributes(dateiname):

    # Nach PDF-Dateien filtern
    if dateiname.endswith(".pdf"):
        
        # Dateinamen korrekt formatieren 
        notenname = dateiname.removesuffix(".pdf")
        notenname = notenname.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
        notenname = notenname.replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue")
        notenname = unicodedata.normalize("NFD", notenname).encode("ascii", "ignore").decode("utf-8")

        # String zwischen "_" aufteilen
        attributes = notenname.split("_")

        # Name der Note aus dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            log("[ERROR]:", "No song name found")
            song = None

        # Instrument aus dem Dateinamen filtern
        try:
            instrument = attributes[1]
        except:
            log("[ERROR]:", f"No instrument found in {attributes[0]}")
            instrument = None

        # Stimme aus Dateinamen filtern 
        try:
            stimme = attributes[2]
        except:
            log("[WARNING]:", f"No part found in {attributes[0]}")
            stimme = None

        if song is None or instrument is None:
            return None

        return song, instrument, stimme

"""
Ueberprueft die Dateipfade aus der Database. Wenn Datei auf Pfad nicht mehr existiert
wird der Eintrag aus der DB geloescht.

Input:  None
Output: Anzahl geloeschter Eintraege (int)
"""
def clean_database():
    # DB Session oeffnen
    session = database.Session()

    # Alle Noten aus der DB auflisten
    alle_noten = session.query(database.Note).all()

    # Zaehler fuer geloeschte Eintraege
    geloescht = 0

    # Ueber DB Eintraege iterieren
    for note in alle_noten:
        if not os.path.exists(note.dateipfad):
            log("[REMOVED]", f"{note.song} - {note.instrument} {note.stimme or ""}")
            session.delete(note)
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
        
        # Playbacks Ordner ueberspringen
        if ordner.lower() == "playbacks":
            continue

        # Unterordner oeffnen + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        if not os.path.isdir(unterordnerPfad):
            continue
        dateienUnterodner = os.listdir(unterordnerPfad)

        # Ueber Dateien im Unterordner iterieren
        for note in dateienUnterodner:

            # Playbacks Ordner ueberspringen
            if note.lower() == "playbacks":
                continue

            # Song, Instrument und Stimme aus Dateinamen auslesen
            result = parse_atrributes(note)

            # Wenn Datei eine PDF
            if result is not None:
                song, instrument, stimme = result

                # Pfad zur Note
                dateipfad = os.path.join(unterordnerPfad, note)

                # Letztes Aenderungsdatum ermitteln
                timestamp = os.path.getmtime(dateipfad)
                version = datetime.fromtimestamp(timestamp)

                # Ist None wenn die Note noch nicht in der DB existiert
                existierende_note = session.query(database.Note).filter(
                    func.lower(database.Note.song) == song.lower(),
                    func.lower(database.Note.instrument) == instrument.lower(),
                    database.Note.stimme == stimme
                ).first()

                # Falls die Note noch nicht existiert neue Note erstellen
                if existierende_note is None:

                    # Neues Objekt in der DB erstellen
                    neue_note = database.Note(
                        song = song,
                        instrument = instrument,
                        stimme = stimme,
                        dateipfad = dateipfad,
                        version = version
                    )

                    log("[ADDED]", f"{song} - {instrument} {stimme or ""}")
                    session.add(neue_note)
                    aenderungen += 1

                # Sonst version vergleichen und updaten falls neuer
                else:
                    if version > existierende_note.version:
                        log("[UPDATED]", f"{song} - {instrument} {stimme or ""}")
                        existierende_note.version = version
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
        command = input("noten_watcher > ")
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
            alle_noten = session.query(database.Note).all()
            for note in alle_noten:
                log("[REMOVED]", f"{note.song} - {note.instrument} {note.stimme or ""}")
            session.query(database.Note).delete()
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