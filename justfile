# build the base image (context = repo root so COPY paths resolve)
build-base:
	docker build -t workspace-base:latest -f images/Dockerfile.base .
