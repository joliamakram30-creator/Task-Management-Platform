from fastapi import FastAPI

app = FastAPI(
    title="Task Management Platform",
    description="Task Management Platform API",
    version="1.0.0",
)


@app.get("/")
def root():
    return {
        "message": "Task Management Platform API is running"
    }


@app.get("/health")
def health_check():
    return {
        "status": "healthy"
    }