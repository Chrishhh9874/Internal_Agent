"""Internal Agent API entry point."""

from fastapi import FastAPI

app = FastAPI(title="Internal Agent")


@app.get("/api/health")
def health() -> dict[str, str]:
    """Health check used by the CI smoke test and the CodeDeploy ValidateService hook."""
    return {"status": "ok"}
