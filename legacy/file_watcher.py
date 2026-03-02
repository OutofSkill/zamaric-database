import os

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
Extrahiert die gefragten Attribute und füllt die Datenbank mit diesen. 

Input:  pfad (str) - Übergeordneter Pfad der Songs
Output: None
"""
def fill_database(pfad):
    # List mit allen Directories im Ordner
    dateien = os.listdir(pfad)

    # Über Unterordner iterieren
    for ordner in dateien:

        # Unterordner "öffnen" + Liste mit Dateien im Unterordner erstellen
        unterordnerPfad = os.path.join(basispfad, ordner)
        dateienUnterodner = os.listdir(unterordnerPfad)
        print(dateienUnterodner)

        # Über Dateien im Unterordner iterieren
        for note in dateienUnterodner:
            result = parse_atrributes(note)
            if result is not None:
                song, instrument, stimme = result

def main():
    fill_database(basispfad)

if __name__ == "__main__":
    main()