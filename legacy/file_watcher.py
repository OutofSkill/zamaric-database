import os
from datetime import datetime
import database
import time

# Pfad zum Ordner mit allen Musiknoten + Playbacks
basispfad = r"C:\Users\phil_\Documents\musikapp\Backend\stuecke"

"""
Parst einen Dateinamen und extrahiert Song, Instrument und Stimme.

Input:  dateiname (str) - z.B. "apt_trompete_1.pdf"
Output: attributes = [Song, Instrument, Stimme]
        Bei fehlendem Wert wird None zurückgegeben
"""
def parse_atrributes(dateiname):

    # Nach PDF-Dateien filtern
    if dateiname.endswith(".pdf"):
        
        # Zum sauberen Arbeiten .pdf vom Ende entfernen
        notenname = dateiname.removesuffix(".pdf")

        # String zwischen "_" aufteilen
        attributes = notenname.split("_")

        # Name der Note au dem Dateinamen filtern
        try:
            song = attributes[0]
        except:
            print("Fehler : Kein Name gefunden")
            song = None
        
        print(song)

        # Instrument aus dem Dateinamen filtern
        try:
            instrument = attributes[1]
        except:
            print("Fehler : kein Instrument gefunden")
            instrument = None
        
        print(instrument)

        # Stimme aus Dateinamen filtern 
        try : 
            stimme = attributes[2]
        except : 
            print("Fehler : Keine Stimme gefunden")
            stimme = None
        print(stimme)

        return song, instrument, stimme


"""
Überprüft die Dateipfade aus der Database. Wenn Datei auf Pfad nicht mehr existiert
wird der Eintrag aus der DB gelöscht.  

Input:  None
Output: None
"""
def clean_database():
    # DB Session öffnen
    session = database.Session()

    # Alle Noten aus der DB auflisten
    alle_noten = session.query(database.Note).all()

    # Über DB einträge iterieren
    for note in alle_noten:
        if not os.path.exists(note.dateipfad):
            session.delete(note)
    
    session.commit()
    session.close()

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

    # Über Unterordner iterieren
    for ordner in dateien:

        # Unterordner "öffnen" + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        dateienUnterodner = os.listdir(unterordnerPfad)
        print(dateienUnterodner)

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

                # Ist None wenn die Note noch nicht ind der DB existiert
                existierende_note = session.query(database.Note).filter_by(
                    song = song,
                    instrument = instrument,
                    stimme = stimme
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

                    # Neues Objekt zur Session hinzufügen
                    session.add(neue_note)

                # Sonst 
                else :
                    if version > existierende_note.version:
                        existierende_note = version

    # Alle neuen Objekte in der DB speichern
    session.commit()

    # DB Session abschließen
    session.close()

def main():
    while True:
        clean_database()
        fill_database(basispfad)
        time.sleep(10)

if __name__ == "__main__":
    main()