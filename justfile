# build the base image (context = repo root so COPY paths resolve)
build-base:
	docker build -t workspace-base:latest -f images/Dockerfile.base .

# build the optional mesh image (Tailscale/Headscale client); needs build-base first
build-mesh:
	docker build -t workspace-mesh:latest -f mesh/Dockerfile .
