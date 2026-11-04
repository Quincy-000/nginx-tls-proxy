import logging

from fastapi import FastAPI, Request

log = logging.getLogger("uvicorn.error")
app = FastAPI()


@app.middleware("http")
async def log_connection(request: Request, call_next):
    # socket peer vs what the proxy claims: the gap between these is check F
    log.info(
        "peer=%s xff=%s xfp=%s path=%s",
        request.client.host if request.client else None,
        request.headers.get("x-forwarded-for"),
        request.headers.get("x-forwarded-proto"),
        request.url.path,
    )
    return await call_next(request)


@app.get("/")
def root():
    return {"service": "app", "message": "hello from behind the proxy"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
