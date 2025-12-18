build-image:
	cd docker && docker build -f Dockerfile.split-k8s -t srsran-split:latest ..
import:
	docker save srsran-split:latest | microk8s ctr image import -

build-ue-image:
	cd docker && docker build -f Dockerfile.srsue -t srsran-ue:latest ..
import-ue:
	docker save srsran-ue:latest | microk8s ctr image import -

# Run command
.PHONY: free5gc cp up du
free5gc:
	helm install free5gc-v1 -n free5gc /home/free5gc/free5gc-helm/charts/free5gc
cp:
	helm install srsran-cucp -n free5gc /home/free5gc/srsran-helm/charts/cucp
up:
	helm install srsran-cuup -n free5gc /home/free5gc/srsran-helm/charts/cuup
du:
	helm install srsran-du -n free5gc /home/free5gc/srsran-helm/charts/du
gnb:
	make cp
	sleep 3
	make up
	sleep 3
	make du
ue:
	helm install srsran-ue -n free5gc /home/free5gc/srsran-helm/charts/ue
gnb-ue:
	make cp
	sleep 3
	make up
	sleep 3
	make du
	sleep 20
	make ue
uninstall-free5gc:
	helm uninstall free5gc-v1 -n free5gc
uninstall-cp:
	helm uninstall srsran-cucp -n free5gc
uninstall-up:
	helm uninstall srsran-cuup -n free5gc
uninstall-du:
	helm uninstall srsran-du -n free5gc
uninstall-ue:
	helm uninstall srsran-ue -n free5gc
uninstall-gnb:
	make uninstall-du
	sleep 3
	make uninstall-up
	sleep 3
	make uninstall-cp
uninstall-all:
	helm uninstall srsran-ue -n free5gc && sleep 2 && helm uninstall srsran-du -n free5gc && sleep 2 && helm uninstall srsran-cuup -n free5gc && sleep 2 && helm uninstall srsran-cucp -n free5gc
check-log:
	cd /home/free5gc/srsRAN_Project_helm && microk8s helm install srsran-cucp ./charts/cucp -n free5gc && sleep 2 && microk8s helm install srsran-cuup ./charts/cuup -n free5gc && sleep 2 && microk8s helm install srsran-du ./charts/du -n free5gc && sleep 10 && microk8s helm uninstall srsran-cucp srsran-cuup srsran-du -n free5gc
tmp:
	iperf3 -s -B 10.0.2.13
	ip link set dev tun_srsue mtu 1350
	iperf3 --bind-dev tun_srsue -c 10.0.2.13 -u -b 20M -t 10