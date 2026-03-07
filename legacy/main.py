import threading
import schedule
import time
import sys
from datetime import datetime, timedelta
import noten_watcher
import playback_watcher

# Uhrzeit an der die DB aktualisiert wird
aktualisierungszeit = "03:00"

def log(tag, message):
    timestamp = datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    print(f"[{timestamp}] {tag} {message}")

stop_event = threading.Event()

def scheduler():
    schedule.every().day.at(aktualisierungszeit).do(noten_watcher.job)
    schedule.every().day.at(aktualisierungszeit).do(playback_watcher.job)

    while not stop_event.is_set():
        schedule.run_pending()
        time.sleep(1)

def listen_for_commands():
    print("Commands: noten cycle, noten fill, noten clean, noten clear")
    print("          playback cycle, playback fill, playback clean, playback clear")
    print("          cycle (both), quit")
    print("")

    while True:
        command = input("musikapp > ")

        if command == "cycle":
            log("[INFO]", "Running full cycle for both watchers...")
            noten_watcher.job()
            playback_watcher.job()

        elif command == "noten cycle":
            noten_watcher.job()
        elif command == "noten fill":
            noten_watcher.fill_database(noten_watcher.basispfad)
            log("[DONE]", "Noten database filled")
        elif command == "noten clean":
            noten_watcher.clean_database()
            log("[DONE]", "Noten database cleaned")
        elif command == "noten clear":
            import database
            session = database.Session()
            alle_noten = session.query(database.Note).all()
            for note in alle_noten:
                log("[REMOVED]", f"{note.song} - {note.instrument} {note.stimme or ""}")
            session.query(database.Note).delete()
            session.commit()
            session.close()
            log("[DONE]", "Noten database cleared")

        elif command == "playback cycle":
            playback_watcher.job()
        elif command == "playback fill":
            playback_watcher.fill_database(playback_watcher.basispfad)
            log("[DONE]", "Playback database filled")
        elif command == "playback clean":
            playback_watcher.clean_database()
            log("[DONE]", "Playback database cleaned")
        elif command == "playback clear":
            import database
            session = database.Session()
            alle_playbacks = session.query(database.Playback).all()
            for playback in alle_playbacks:
                log("[REMOVED]", f"{playback.song} - {playback.geschwindigkeit}")
            session.query(database.Playback).delete()
            session.commit()
            session.close()
            log("[DONE]", "Playback database cleared")

        elif command == "quit":
            log("[INFO]", "Shutting down...")
            stop_event.set()
            sys.exit(0)

        else:
            log("[INFO]", f"Unknown command: {command}")

def main():
    log("[INFO]", "Starting musikapp backend...")

    # Scheduler in separatem Thread starten
    scheduler_thread = threading.Thread(target=scheduler, daemon=True)
    scheduler_thread.start()

    log("[INFO]", f"Automated cycle scheduled at {aktualisierungszeit}")

    # Terminal-Interface starten
    listen_for_commands()

if __name__ == "__main__":
    main()
