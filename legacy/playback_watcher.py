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

"""
Parst einen Dateinamen und extrahiert Song und Geschwindigkeit.

Input:  dateiname (str) - z.B. "apt_normal.mp3"
Output: attributes = [Song, Geschwindigkeit]
        Bei fehlendem Wert wird None zurückgegeben
"""
def parse_atrributes(dateiname):

    # Nach PDF-Dateien filtern
    if dateiname.endswith(".mp3"):
        
        # Dateinamen korrekt formatieren 
        playbackname = dateiname.removesuffix(".mp3")
        playbackname = playbackname.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue")
        playbackname = playbackname.replace("Ä", "Ae").replace("Ö", "Oe").replace("Ü", "Ue")
        playbackname = unicodedata.normalize('NFD', playbackname).encode('ascii', 'ignore').decode('utf-8')

        # String zwischen "_" aufteilen
        attributes = playbackname.split("_")

        # Name des Playbacks aus dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            print("[ERROR]: No song name found")
            song = None

        # Geschwindigkeit aus dem Dateinamen filtern
        try:
            geschwindigkeit = attributes[1]
        except:
            print("[ERROR]: No Speed found")
            geschwindigkeit = None

        return song, geschwindigkeit

"""
Überprüft die Dateipfade aus der Database. Wenn Datei auf Pfad nicht mehr existiert wird der Eintrag aus der DB gelöscht.  

Input:  None
Output: Anzahl gelöschter Einträge (int)
"""
def clean_database():
    # DB Session öffnen
    session = database.Session()

    # Alle Playbacks aus der DB auflisten
    alle_playbacks = session.query(database.Playback).all()

    # Zähler für gelöschte Einträge
    geloescht = 0

    # Über DB einträge iterieren
    for playbacks in alle_playbacks:
        if not os.path.exists(playbacks.dateipfad):
            print(f"[REMOVED] {playbacks.song} - {playbacks.geschwindigkeit}")
            session.delete(playbacks)
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

        # Unterordner "öffnen" + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        dateienUnterodner = os.listdir(unterordnerPfad)

        # Über Dateien im Unterordner iterieren
        for note in dateienUnterodner:
            
            # Wir suchen den Playbacks Ordner
            if note == "playbacks" :

                # Playbacks-Ordner "öffnen" + Liste mit Dateien im Unterordner erstellen
                playbacksPath = os.path.join(unterordnerPfad, note)
                playbacks = os.listdir(playbacksPath)
                

                for playback in playbacks :
            
                    # Song und Geschwindigkeit aus Dateinamen auslesen
                    result = parse_atrributes(playback)

                    # Wenn Datei eine MP3
                    if result is not None:
                        song, geschwindigkeit = result

                        # Pfad zum Playback
                        dateipfad = os.path.join(playbacksPath, playback)

                        # letztes Änderungsdatum ermitteln
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

                            print(f"[ADDED] {song} - {geschwindigkeit}")
                            session.add(neue_playback)
                            aenderungen += 1

                        # Sonst version vergleichen und updaten falls neuer
                        else:
                            if version > existierende_playback.version:
                                print(f"[UPDATED] {song} - {geschwindigkeit}")
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
            alle_playbacks = session.query(database.Playback).all()
            for playback in alle_playbacks:
                print(f"[REMOVED] {playback.song} - {playback.geschwindigkeit}")
            session.query(database.Playback).delete()
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