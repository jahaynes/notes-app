# k3s

Frontend and backend behind k3s's bundled Traefik, on one origin,
`https://notes.johnhaynes.dev`:

| Path    | Goes to                          |
|---------|----------------------------------|
| `/`     | `frontend` (nginx, static app)   |
| `/api/` | `backend`, with `/api` stripped  |

The notes database is SQLite on a `local-path` volume, so the backend
runs as a single replica.

## Images

The images build from the local checkout, uncommitted changes included,
with the repo root as the context. From the repo root:

```sh
podman build -f deployment/backend/Dockerfile  -t notes-app-backend  .
podman build -f deployment/frontend/Dockerfile -t notes-app-frontend .
```

The manifests use these locally built images (`imagePullPolicy: Never`),
so import them into k3s's containerd after every build:

```sh
podman save localhost/notes-app-backend:latest  | sudo k3s ctr images import -
podman save localhost/notes-app-frontend:latest | sudo k3s ctr images import -
```

## HTTPS

cert-manager gets a Let's Encrypt certificate and renews it. The
challenge is HTTP-01, so `notes.johnhaynes.dev` must resolve to the
node and ports 80 and 443 must be open to the internet.

Install cert-manager once per cluster, and wait for it to come up:

```sh
sudo k3s kubectl apply -f cert-manager/helmchart.yaml
sudo k3s kubectl -n cert-manager rollout status deployment cert-manager-webhook
```

## First deploy

The backend signs login tokens with `JWT_SECRET` (at least 32 bytes):

```sh
sudo k3s kubectl create namespace notes-app
sudo k3s kubectl -n notes-app create secret generic backend \
    --from-literal=JWT_SECRET="$(head -c 32 /dev/urandom | base64)"
sudo k3s kubectl apply -k .
```

Watch the certificate get issued (a minute or so):

```sh
sudo k3s kubectl -n notes-app get certificate notes -w
```

If it stays not ready, `kubectl -n notes-app describe challenge` says
why. Until it's issued, Traefik serves its self-signed default.

Then open `https://notes.johnhaynes.dev/`, and log in with server
`notes.johnhaynes.dev/api` (no scheme means https).

## Redeploy after a rebuild

The tag stays `latest`, so restart to pick up the newly imported image:

```sh
sudo k3s kubectl -n notes-app rollout restart deployment backend frontend
```
