import os
from datetime import datetime, timedelta
import database
import time
import schedule
import unicodedata
from sqlalchemy import func
import threading

# Pfad zum Ordner mit allen Musiknoten + Playbacks
basispfad = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stuecke")

# Uhrzeit an der die DB aktualisiert wird
aktualisierungszeit = "03:00"

def log(tag, message):
    timestamp = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    print(f"[{timestamp}] {tag} {message}")

"""
Parst einen Dateinamen und extrahiert Song, Instrument, Transposition und Level.

Input:  dateiname (str) - z.B. "apt_trompete_1.pdf"
Output: attributes = [Song, Instrument, Transposition, Level]
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

        # String zwischen "-" aufteilen
        attributes = notenname.split("-")

        # Name der Note aus dem Dateinamen filtern
        try:
            song = attributes[0].strip()
        except:
            log("[ERROR]:", f"No song name found in {notenname}")
            song = None

        try:
            if " in " in attributes[1]:
                # String ohne Songnamen zwischen "in" aufteilen
                has_transposition = True
                attributes = attributes[1].split(" in ")
            else:
                transposition = None
                has_transposition = False
                attributes = attributes[1].split()
        except:
            log("[ERROR]:", f"No instrument found in {notenname}")
            return None

        # Instrument aus dem Dateinamen filtern
        try:
            instrument = attributes[0].strip()
        except:
            log("[ERROR]:", f"No instrument found in {notenname}")
            instrument = None

        try:
            # String ohne Instrument zwischen Leerzeichen aufteilen
            attributes = attributes[1].split()
        except:
            log("[WARNING]:", f"No transposition found in {notenname}")
            log("[WARNING]:", f"No level found in {notenname}")

        if has_transposition == True:
            # Transposition aus dem Dateinamen filtern
            try:
                transposition = attributes[0].strip()
            except:
                log("[WARNING]:", f"No transposition found in {notenname}")
                transposition = None
        
        # Level aus Dateinamen filtern
        try:
            if has_transposition == True:
                level = attributes[1].strip()
            elif instrument != attributes[0]:
                level = attributes[0].strip()
            else:
                level = None
        except:
            log("[WARNING]:", f"No level found in {notenname}")
            level = None

        if song is None or instrument is None:
            return None

        return song, instrument, transposition, level

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
            log("[REMOVED]", f"{note.song} - {note.instrument} in {note.transposition} {note.level or ""}")
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

            # Song, Instrument, Transposition und Level aus Dateinamen auslesen
            result = parse_atrributes(note)

            # Wenn Datei eine PDF
            if result is not None:
                song, instrument, transposition, level = result

                # Pfad zur Note
                dateipfad = os.path.join(unterordnerPfad, note)

                # Letztes Aenderungsdatum ermitteln
                timestamp = os.path.getmtime(dateipfad)
                version = datetime.fromtimestamp(timestamp)

                # Ist None wenn die Note noch nicht in der DB existiert
                existierende_note = session.query(database.Note).filter(
                    func.lower(database.Note.song) == song.lower(),
                    func.lower(database.Note.instrument) == instrument.lower(),
                    func.lower(database.Note.transposition) == (transposition.lower() if transposition else None),
                    database.Note.level == level
                ).first()

                # Falls die Note noch nicht existiert neue Note erstellen
                if existierende_note is None:

                    # Neues Objekt in der DB erstellen
                    neue_note = database.Note(
                        song = song,
                        instrument = instrument,
                        transposition = transposition,
                        level = level,
                        dateipfad = dateipfad,
                        version = version
                    )

                    log("[ADDED]", f"{song} - {instrument} in {transposition} {level or ""}")
                    session.add(neue_note)
                    aenderungen += 1

                # Sonst version vergleichen und updaten falls neuer
                else:
                    if version > existierende_note.version:
                        log("[UPDATED]", f"{song} - {instrument} in {transposition} {level or ""}")
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
                log("[REMOVED]", f"{note.song} - {note.instrument} in {note.transposition} {note.level or ""}")
            session.query(database.Note).delete()
            session.commit()
            session.close()
            log("[DONE]", "Database cleared")
        elif command == "quit":
            log("[INFO]", "Shutting down...")
            stop_event.set()
            return

def main():
    def job_with_prompt():
        job()
        print("noten_watcher > ", end="", flush=True)

    # Jeden Tag um 03:00 Uhr
    schedule.every().day.at(aktualisierungszeit).do(job_with_prompt)

    # Terminal-Listener in separatem Thread starten
    thread = threading.Thread(target=listen_for_commands, daemon=True)
    thread.start()

    while not stop_event.is_set():
        schedule.run_pending()
        time.sleep(1)

if __name__ == "__main__":
    main()