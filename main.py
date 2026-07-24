import uvicorn


if __name__ == "__main__":
    uvicorn.run(
        "wps_converter.app:create_app",
        factory=True,
        host="0.0.0.0",
        port=8000,
        workers=1,
    )
