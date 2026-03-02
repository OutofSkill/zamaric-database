from fastapi import FastAPI

app = FastAPI()

@app.get("/noten")
def get_noten():
    return [{"id": 1, "titel": "Sonate"}, {"id": 2, "titel": "Walzer"}]