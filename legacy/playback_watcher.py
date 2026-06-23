import os
from datetime import datetime, timedelta
import database
import time
import schedule
import unicodedata
from sqlalchemy import func
import threading
import json
from mutagen.mp3 import MP3

# Pfad zum Ordner mit allen Musiknoten + Playbacks
basispfad = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stuecke")

# Uhrzeit an der die DB aktualisiert wird
aktualisierungszeit = "03:00"

def log(tag, message):
    timestamp = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    print(f"[{timestamp}] {tag} {message}")

"""
Parst einen Dateinamen und extrahiert Song und Typ.

Input:  dateiname (str) - z.B. "apt_normal.mp3"
Output: attributes = [Song, Typ]
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

        # String zwischen "-" aufteilen
        attributes = playbackname.split("-")

        # Name des Playbacks aus dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            log("[ERROR]:", "No song name found")
            song = None

        # Typ aus dem Dateinamen filtern
        try:
            typ = attributes[1]
        except:
            log("[WARNING]:", f"No type found in {attributes[0]}")
            typ = None

        if song is None:
            return None

        return song, typ

def ermittle_duration(dateipfad):
    try:
        audio = MP3(dateipfad)
        return int(round(audio.info.length * 1000))
    except Exception:
        log("[WARNING]:", f"Duration konnte nicht ermittelt werden fuer {dateipfad}")
        return None

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
            log("[REMOVED]", f"{playback.song} - {playback.typ}")
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
    # DB Session oeffnen
    session = database.Session()

    # Zaehler fuer Aenderungen
    aenderungen = 0

    # Ueber Kategorie-Ordner iterieren
    for kategorie_ordner in os.listdir(pfad):
        kategorie_pfad = os.path.join(pfad, kategorie_ordner)
        if not os.path.isdir(kategorie_pfad):
            continue

        # Kategorie-Nummer aus Ordnernamen extrahieren (z.B. "2 Absolute Beginners..." -> "2")
        kategorie = kategorie_ordner.split()[0]

        # Playbacks-Unterordner suchen
        playbacks_pfad = os.path.join(kategorie_pfad, "Playbacks")
        if not os.path.isdir(playbacks_pfad):
            continue

        # Ueber Song-Ordner iterieren
        for song_ordner in os.listdir(playbacks_pfad):
            song_ordner_pfad = os.path.join(playbacks_pfad, song_ordner)
            if not os.path.isdir(song_ordner_pfad):
                continue

            # Einzaehler-Unterordner scannen
            einzaehler_pfad = os.path.join(song_ordner_pfad, "Einzaehler")
            if os.path.isdir(einzaehler_pfad):
                for einzaehler in os.listdir(einzaehler_pfad):
                    if not einzaehler.endswith(".mp3"):
                        continue

                    # Keyword = Dateiname ohne Songname-Prefix und ohne .mp3
                    dateiname_ohne_endung = einzaehler.removesuffix(".mp3")
                    song_prefix = song_ordner + " "
                    if dateiname_ohne_endung.startswith(song_prefix):
                        keyword = dateiname_ohne_endung[len(song_prefix):]
                    else:
                        keyword = dateiname_ohne_endung

                    keyword = keyword.strip()
                    einzaehler_dateipfad = os.path.join(einzaehler_pfad, einzaehler)
                    timestamp = os.path.getmtime(einzaehler_dateipfad)
                    version = datetime.fromtimestamp(timestamp)
                    typ = f"Einzaehler {keyword}"
                    duration = ermittle_duration(einzaehler_dateipfad)

                    existierender_einzaehler = session.query(database.Playback).filter(
                        func.lower(database.Playback.song) == song_ordner.lower(),
                        func.lower(database.Playback.typ) == typ.lower(),
                    ).first()

                    if existierender_einzaehler is None:
                        neuer_einzaehler = database.Playback(
                            kategorie = kategorie,
                            song = song_ordner,
                            typ = typ,
                            buchstaben = None,
                            duration = duration,
                            dateipfad = einzaehler_dateipfad,
                            version = version
                        )
                        log("[ADDED]", f"{song_ordner} - {typ}")
                        session.add(neuer_einzaehler)
                        aenderungen += 1
                    else:
                        if version > existierender_einzaehler.version or existierender_einzaehler.duration != duration:
                            log("[UPDATED]", f"{song_ordner} - {typ}")
                            existierender_einzaehler.version = version
                            existierender_einzaehler.duration = duration
                            aenderungen += 1

            # Ueber Dateien im Song-Ordner iterieren
            for playback in os.listdir(song_ordner_pfad):

                if not playback.endswith(".mp3"):
                    continue

                # Song und Typ aus Dateinamen auslesen
                result = parse_atrributes(playback)

                # Wenn Datei eine MP3
                if result is not None:
                    song, typ = result

                    # Pfad zum Playback
                    dateipfad = os.path.join(song_ordner_pfad, playback)

                    # Letztes Aenderungsdatum ermitteln
                    timestamp = os.path.getmtime(dateipfad)
                    version = datetime.fromtimestamp(timestamp)

                    duration = ermittle_duration(dateipfad)

                    # TXT-Datei mit Buchstaben einlesen (gleicher Name, andere Endung)
                    txt_pfad = dateipfad.removesuffix(".mp3") + ".txt"
                    buchstaben_json = None
                    if os.path.exists(txt_pfad):
                        buchstaben = []
                        with open(txt_pfad, "r", encoding="utf-8") as f:
                            for zeile in f:
                                zeile = zeile.strip()
                                if not zeile:
                                    continue
                                teile = zeile.split()
                                if len(teile) >= 3:
                                    buchstaben.append({
                                        "buchstabe": teile[0],
                                        "timestamp": teile[1],
                                        "taktart": teile[2]
                                    })
                        if buchstaben:
                            buchstaben_json = json.dumps(buchstaben)

                    # Ist None wenn das Playback noch nicht in der DB existiert
                    existierende_playback = session.query(database.Playback).filter(
                        func.lower(database.Playback.song) == song.lower(),
                        func.lower(database.Playback.typ) == (typ.lower() if typ else None),
                    ).first()

                    # Falls das Playback noch nicht existiert neues Playback erstellen
                    if existierende_playback is None:

                        # Neues Objekt in der DB erstellen
                        neue_playback = database.Playback(
                            kategorie = kategorie,
                            song = song,
                            typ = typ,
                            buchstaben = buchstaben_json,
                            duration = duration,
                            dateipfad = dateipfad,
                            version = version
                        )

                        log("[ADDED]", f"{song} - {typ}")
                        session.add(neue_playback)
                        aenderungen += 1

                    # Sonst version vergleichen und updaten falls neuer
                    else:
                        if version > existierende_playback.version or existierende_playback.buchstaben != buchstaben_json or existierende_playback.duration != duration:
                            log("[UPDATED]", f"{song} - {typ}")
                            existierende_playback.version = version
                            existierende_playback.buchstaben = buchstaben_json
                            existierende_playback.duration = duration
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
                log("[REMOVED]", f"{playback.song} - {playback.typ}")
            session.query(database.Playback).delete(synchronize_session=False)
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
        print("playback_watcher > ", end="", flush=True)

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