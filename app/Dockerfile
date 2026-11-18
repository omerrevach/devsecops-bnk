# Both base images come from the internal Harbor mirror, pinned by digest.
# Replace the <digest> values with the digests shown in Harbor (Phase 7).

# ---- Stage 1: install dependencies offline (this stage has pip) ----
FROM harbor.lab.internal/mirror/library/python:3.13-slim@sha256:<digest> AS build
WORKDIR /app
COPY requirements.txt .
# wheels/ is filled by the CI "wheels" job from GitLab's internal PyPI registry.
COPY wheels/ /wheels/
RUN pip install --no-index --find-links /wheels --require-hashes \
      --target /app/deps -r requirements.txt

# ---- Stage 2: minimal runtime (no shell, no pip, non-root) ----
FROM harbor.lab.internal/mirror/distroless/python3-debian13:nonroot@sha256:<digest>
WORKDIR /app
COPY --from=build /app/deps /app/deps
COPY app.py .
ENV PYTHONPATH=/app/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["python3", "/app/app.py"]
