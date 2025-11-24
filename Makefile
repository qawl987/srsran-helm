build-image:
	cd docker && docker build -f Dockerfile.split-k8s -t srsran-split:latest ..
import:
	docker save srsran-split:latest | microk8s ctr image import -

build-ue-image:
	cd docker && docker build -f Dockerfile.srsue -t srsran-ue:latest ..
import-ue:
	docker save srsran-ue:latest | microk8s ctr image import -