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
aktualisierungszeit = "20:52"

"""
Parst einen Dateinamen und extrahiert Song, Instrument und Stimme.

Input:  dateiname (str) - z.B. "apt_trompete_1.pdf"
Output: attributes = [Song, Instrument, Stimme]
        Bei fehlendem Wert wird None zurückgegeben
"""
def parse_atrributes(dateiname):

    # Nach PDF-Dateien filtern
    if dateiname.endswith(".pdf"):
        
        # Dateinamen korrekt formatieren 
        notenname = dateiname.removesuffix(".pdf")
        notenname = notenname.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
        notenname = notenname.replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue")
        notenname = unicodedata.normalize('NFD', notenname).encode('ascii', 'ignore').decode('utf-8')

        # String zwischen "_" aufteilen
        attributes = notenname.split("_")

        # Name der Note aus dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            print("[ERROR]: No song name found")
            song = None

        # Instrument aus dem Dateinamen filtern
        try:
            instrument = attributes[1]
        except:
            print("[ERROR]: No instrument found")
            instrument = None

        # Stimme aus Dateinamen filtern 
        try : 
            stimme = attributes[2]
        except : 
            print("[ERROR]: No part found")
            stimme = None

        return song, instrument, stimme

"""
Überprüft die Dateipfade aus der Database. Wenn Datei auf Pfad nicht mehr existiert
wird der Eintrag aus der DB gelöscht.  

Input:  None
Output: Anzahl gelöschter Einträge (int)
"""
def clean_database():
    # DB Session öffnen
    session = database.Session()

    # Alle Noten aus der DB auflisten
    alle_noten = session.query(database.Note).all()

    # Zähler für gelöschte Einträge
    geloescht = 0

    # Über DB einträge iterieren
    for note in alle_noten:
        if not os.path.exists(note.dateipfad):
            print(f"[REMOVED] {note.song} - {note.instrument} {note.stimme or ''}")
            session.delete(note)
            geloescht += 1
    
    session.commit()
    session.close()

    return geloescht

"""
Extrahiert die gefragten Attribute und füllt die Datenbank mit diesen. 

Input:  pfad (str) - Übergeordneter Pfad der Songs
Output: None
"""
def fill_database(pfad):
    # List mit allen Directories im Ordner
    dateien = os.listdir(pfad)

    # DB Session öffnen 
    session = database.Session()

    # Zähler für Änderungen
    aenderungen = 0

    # Über Unterordner iterieren
    for ordner in dateien:
        
        # Playbacks Ordner überspringen
        if ordner == "playbacks":
            continue

        # Unterordner "öffnen" + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        dateienUnterodner = os.listdir(unterordnerPfad)

        # Über Dateien im Unterordner iterieren
        for note in dateienUnterodner:

            # Song, Instrument und Stimme aus Dateinamen auslesen
            result = parse_atrributes(note)

            # Wenn Datei eine PDF
            if result is not None:
                song, instrument, stimme = result

                # Pfad zur Note
                dateipfad = os.path.join(unterordnerPfad, note)

                # letztes Änderungsdatum ermitteln
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

                    print(f"[ADDED] {song} - {instrument} {stimme or ''}")
                    session.add(neue_note)
                    aenderungen += 1

                # Sonst version vergleichen und updaten falls neuer
                else:
                    if version > existierende_note.version:
                        print(f"[UPDATED] {song} - {instrument} {stimme or ''}")
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
        print("[INFO] No changes found")

    naechster_durchlauf = datetime.now().replace(hour=3, minute=0, second=0, microsecond=0)
    if naechster_durchlauf < datetime.now():
        naechster_durchlauf += timedelta(days=1)

    print(f"[DONE] Cycle completed at {datetime.now().strftime('%H:%M:%S')} - Next automated cycle at {naechster_durchlauf.strftime('%d.%m.%Y %H:%M')}")

def listen_for_commands():
    while True:
        command = input()
        if command == "cycle":
            job()
        elif command == "fill":
            fill_database(basispfad)
            print("[DONE] Database filled")
        elif command == "clean":
            clean_database()
            print("[DONE] Database cleaned")
        elif command == "clear":
            session = database.Session()
            alle_noten = session.query(database.Note).all()
            for note in alle_noten:
                print(f"[REMOVED] {note.song} - {note.instrument} {note.stimme or ''}")
            session.query(database.Note).delete()
            session.commit()
            session.close()
            print("[DONE] Database cleared")

def main():
    # Jeden Tag um 03:00 Uhr
    schedule.every().day.at(aktualisierungszeit).do(job)

    # Terminal-Listener in separatem Thread starten
    thread = threading.Thread(target=listen_for_commands, daemon=True)
    thread.start()

    while True:
        schedule.run_pending()
        time.sleep(30)

if __name__ == "__main__":
    main()