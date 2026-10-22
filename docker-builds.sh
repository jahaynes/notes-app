#!/bin/bash

echo "Building backend"
podman build -f deployment/backend/Dockerfile -t localhost/notes-app-backend:latest .

echo "Building frontend"
podman build -f deployment/frontend/Dockerfile -t localhost/notes-app-frontend:latest .
