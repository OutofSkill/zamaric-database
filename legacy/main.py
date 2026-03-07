import threading
import time
import schedule
import database
import noten_watcher
import playback_watcher

stop_event = threading.Event()

HILFE = """
Befehle:
  cycle   - DB bereinigen und neu befuellen
  fill    - Ordner scannen, neue/geaenderte Dateien eintragen
  clean   - Eintraege loeschen deren Datei nicht mehr existiert
  clear   - Alle Eintraege aus der DB loeschen
  quit    - Programm beenden

Prefix fuer gezielten Zugriff:
  noten <befehl>    - Nur Noten-Watcher
  playback <befehl> - Nur Playback-Watcher
  <befehl>          - Beide Watcher
"""

def run_schedules():
    while not stop_event.is_set():
        schedule.run_pending()
        time.sleep(1)

def handle_noten(cmd):
    if cmd == "cycle":
        noten_watcher.job()
    elif cmd == "fill":
        noten_watcher.fill_database(noten_watcher.basispfad)
        noten_watcher.log("[DONE]", "Database filled")
    elif cmd == "clean":
        noten_watcher.clean_database()
        noten_watcher.log("[DONE]", "Database cleaned")
    elif cmd == "clear":
        session = database.Session()
        alle_noten = session.query(database.Note).all()
        for note in alle_noten:
            noten_watcher.log("[REMOVED]", f"{note.song} - {note.instrument} in {note.transposition} {note.level or ''}")
        session.query(database.Note).delete()
        session.commit()
        session.close()
        noten_watcher.log("[DONE]", "Database cleared")

def handle_playback(cmd):
    if cmd == "cycle":
        playback_watcher.job()
    elif cmd == "fill":
        playback_watcher.fill_database(playback_watcher.basispfad)
        playback_watcher.log("[DONE]", "Database filled")
    elif cmd == "clean":
        playback_watcher.clean_database()
        playback_watcher.log("[DONE]", "Database cleaned")
    elif cmd == "clear":
        session = database.Session()
        alle_playbacks = session.query(database.Playback).all()
        for playback in alle_playbacks:
            playback_watcher.log("[REMOVED]", f"{playback.song} - {playback.typ}")
        session.query(database.Playback).delete()
        session.commit()
        session.close()
        playback_watcher.log("[DONE]", "Database cleared")

def listen_for_commands():
    print(HILFE)
    while True:
        command = input("musikapp > ").strip()
        if not command:
            continue

        parts = command.split(' ', 1)
        if len(parts) == 2 and parts[0] in ('noten', 'playback'):
            prefix, cmd = parts
        else:
            prefix, cmd = None, parts[0]

        if cmd == "quit":
            noten_watcher.log("[INFO]", "Shutting down...")
            stop_event.set()
            return
        elif cmd not in ("cycle", "fill", "clean", "clear"):
            print(HILFE)
            continue

        if prefix == 'noten':
            handle_noten(cmd)
        elif prefix == 'playback':
            handle_playback(cmd)
        else:
            handle_noten(cmd)
            handle_playback(cmd)

def main():
    schedule.every().day.at(noten_watcher.aktualisierungszeit).do(noten_watcher.job)
    schedule.every().day.at(playback_watcher.aktualisierungszeit).do(playback_watcher.job)

    schedule_thread = threading.Thread(target=run_schedules, daemon=True)
    schedule_thread.start()

    listen_for_commands()

if __name__ == "__main__":
    main()
