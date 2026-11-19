#Base images come from our Harbor mirror and are pinned by digest (the image fingerprint)
#<digest> is a placeholder, make up puts the real digest from Harbor here before pushing to GitLab

#Build stage: install the Python packages without internet
FROM harbor.lab.internal/mirror/library/python:3.13-slim@sha256:<digest> AS build
WORKDIR /app
COPY requirements.txt .
#wheels/ holds the packages, downloaded by the CI wheels job from GitLab's internal package registry
COPY wheels/ /wheels/
#--no-index means never go online, --require-hashes rejects any package that was changed
RUN pip install --no-index --find-links /wheels --require-hashes \
      --target /app/deps -r requirements.txt

#Runtime stage: small distroless image with no shell and no pip
FROM harbor.lab.internal/mirror/distroless/python3-debian13:nonroot@sha256:<digest>
WORKDIR /app
COPY --from=build /app/deps /app/deps
COPY app.py .
ENV PYTHONPATH=/app/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
#65532 is the standard nonroot user, the app never runs as root
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["python3", "/app/app.py"]
