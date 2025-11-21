build-image:
	docker build -f docker/Dockerfile.split-k8s -t srsran-split:latest .
import:
	docker save srsran-split:latest | microk8s ctr image import -