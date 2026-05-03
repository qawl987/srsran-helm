# srsRAN Helm

基於 Helm chart 與 Docker image build scripts 實作的 srsUE / GNU Radio 測試部署專案。此專案早期用於手動部署 srsRAN split gNB；目前主要用途是部署 UE、multi-UE ZMQ bridge 與 iperf 測試工具，連接由 Nephio / `srsran-operator` 部署出的 srsRAN gNB。

## 概述

`srsran-helm` 是 srsRAN / free5GC / Nephio 實驗環境中的 UE 與測試端部署層。現在的主線不是再用 Helm 部署 gNB，而是讓 Nephio pipeline 管理 gNB lifecycle，這個 repo 負責部署不需要 Nephio 化的測試元件：

- UE1 / UE2：使用 srsUE + ZMQ 連接 Nephio 部署的 DU
- GNU Radio breaker：two-UE ZMQ bridge，負責把 DU downlink stream 分發給多個 UE，並合併 UE uplink stream
- iperf 測試命令：進入 UE network namespace，透過 `uesimtun0` 驗證 UE ↔ UPF/N6 的流量
- Docker image build context：保留 srsUE、GNU Radio breaker，以及早期 split gNB image build 材料

這個專案和 `srsran-operator` 的分工是：`srsran-operator` 由 Nephio 觸發並部署 CU-CP/CU-UP/DU；`srsran-helm` 則手動部署 UE / GNU Radio bridge / 測試命令。UE 是測試端資源，沒有必要放進 Nephio workload pipeline，因此保留 Helm 方式更直接。

### 架構圖

```
┌─────────────────────────────────────────────────────────────────┐
│                    Nephio / Operator Layer                      │
│                                                                 │
│  E2E Intent ──▶ srsran-operator ──▶ CU-CP / CU-UP / DU          │
│                                      │                          │
│                                      │ DU ZMQ on f1u subnet     │
└──────────────────────────────────────┼──────────────────────────┘
                                       │
                                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                       srsran-helm Layer                         │
│                                                                 │
│  make gnu                make ue1                 make ue2      │
│  ┌──────────────┐        ┌──────────────┐        ┌───────────┐ │
│  │ GNU Radio    │◀──────▶│ srsUE UE1    │        │ srsUE UE2 │ │
│  │ ZMQ bridge   │◀──────▶│ IMSI ...001  │        │ IMSI ...002│ │
│  └──────┬───────┘        └──────┬───────┘        └─────┬─────┘ │
│         │                       │ uesimtun0             │       │
│         │                       ▼                       ▼       │
│         │              make iperf-ue1          make iperf-ue2   │
│         ▼                                                       │
│  DU ZMQ endpoint from Nephio-deployed srsRAN                    │
└─────────────────────────────────────────────────────────────────┘
```

## 功能特性

### 1. 目前主線：UE 與測試端 Helm 部署

目前最常用的 Makefile target 是：

| Target | 用途 |
|--------|------|
| `make ue1` | 部署 UE1，IMSI `208930000000001`，連接 GNU Radio bridge / Nephio DU |
| `make ue2` | 部署 UE2，IMSI `208930000000002`，連接 GNU Radio bridge / Nephio DU |
| `make gnu` | 由 `multi_ue_scenario.grc` 產生 GNU Radio flow graph 並部署 bridge |
| `make iperf-ue1` | 進入 UE1 network namespace，透過 `uesimtun0` 對 `10.0.1.254` 做 UDP iperf3 |
| `make iperf-ue2` | 進入 UE2 network namespace，透過 `uesimtun0` 對 `10.0.1.253` 做 UDP iperf3 |

UE 與 GNU Radio bridge 預設部署到 workload cluster：

```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig
```

UE namespace 會由 Makefile 建立並標上 privileged Pod Security labels，因為 srsUE 需要 `NET_ADMIN`、`NET_RAW` 與 tun device。

### 2. UE Chart

`charts/ue` 部署 srsUE，透過 ZMQ 與 Nephio 部署出的 DU 對接。

主要資源：

| 類型 | 名稱 | 說明 |
|------|------|------|
| ConfigMap | `srsran-ue1-config` / `srsran-ue2-config` | 產生 `/etc/srsran/ue.conf` |
| Deployment | `srsran-ue1` / `srsran-ue2` | 執行 `srsue /etc/srsran/ue.conf` |
| NetworkAttachmentDefinition | `zmqnetwork-srsran-ue1` / `zmqnetwork-srsran-ue2` | UE ZMQ secondary network |
| ServiceAccount | `srsran-ue1` / `srsran-ue2` | UE pod 使用 |

UE1/UE2 values 專門用來連接 Nephio DU 的 `172.6.0.0/24` F1U/ZMQ subnet：

| values file | Make target | IMSI | Slice SD | ZMQ IP | ZMQ device args |
|-------------|-------------|------|----------|--------|-----------------|
| `values_ue1.yaml` | `make ue1` | `208930000000001` | `66051` (`0x010203`) | `172.6.0.3` | `tx_port=tcp://172.6.0.3:2001,rx_port=tcp://172.6.0.1:2100` |
| `values_ue2.yaml` | `make ue2` | `208930000000002` | `1122867` (`0x112233`) | `172.6.0.4` | `tx_port=tcp://172.6.0.4:2002,rx_port=tcp://172.6.0.1:2200` |

兩個 UE 都會在 NAS 設定中使用：

```ini
[nas]
apn = internet
apn_protocol = ipv4

[gw]
ip_devname = uesimtun0
ip_netmask = 255.255.255.0
```

### 3. GNU Radio Breaker Chart

`charts/gnu-breaker` 部署 GNU Radio Python flow graph，作為 multi-UE ZMQ bridge。

主要資源：

| 類型 | 名稱 | 說明 |
|------|------|------|
| ConfigMap | `gnu-breaker-config` | 掛載 `multi_ue_scenario.py` |
| Deployment | `gnu-breaker` | 執行 `python3 -u /config/multi_ue_scenario.py` |
| NetworkAttachmentDefinition | `gnu-breaker-macvlan` | ZMQ bridge network |

`multi_ue_scenario.py` 由 `multi_ue_scenario.grc` 透過 `grcc` 產生。Makefile 的 `make gnu` 會先重新產生 Python，再部署 Helm chart：

```bash
grcc multi_ue_scenario.grc -o ./charts/gnu-breaker/files/
```

目前 flow graph 對應 Nephio DU + UE1 + UE2：

| Endpoint | 位址 | 用途 |
|----------|------|------|
| DU source | `tcp://172.6.0.0:2000` | DU downlink stream |
| UE1 source | `tcp://172.6.0.3:2001` | UE1 uplink stream |
| UE2 source | `tcp://172.6.0.4:2002` | UE2 uplink stream |
| GNU sink for DU/UE RX | `tcp://172.6.0.1:2001` | bridge endpoint |
| UE1 sink | `tcp://172.6.0.1:2100` | UE1 downlink bridge |
| UE2 sink | `tcp://172.6.0.1:2200` | UE2 downlink bridge |

### 4. iperf 測試命令

Makefile 提供兩個測試命令：

```bash
make iperf-ue1
make iperf-ue2
```

這兩個 target 會：

1. 在 KIND worker node 中用 `crictl ps` 找到 UE pod/container
2. 用 `crictl inspect` 取得 UE container PID
3. 透過 `nsenter -t <PID> -n` 進入 UE network namespace
4. 從 `uesimtun0` 發送 UDP iperf3 traffic

預設測試目標：

| Target | Server IP | 頻寬 | 時間 |
|--------|-----------|------|------|
| `make iperf-ue1` | `10.0.1.254` | `1.5M` UDP | 60 秒 |
| `make iperf-ue2` | `10.0.1.253` | `1.5M` UDP | 30 秒 |

這些 IP 通常對應 UPF/N6 側的 iperf server 測試位址。

### 5. Legacy gNB Helm Charts

`charts/cucp`、`charts/cuup`、`charts/du` 是早期手動部署驗證 split gNB 的 Helm chart。現在主要 gNB deployment 已移到 Nephio / `srsran-operator`，因此這三個 chart 保留作為歷史驗證、image debug 與對照用。

#### CU-CP Chart

`charts/cucp` 部署 srsRAN CU-CP。

主要資源：

| 類型 | 名稱 | 說明 |
|------|------|------|
| ConfigMap | `srsran-cucp-config` | 產生 `/etc/config/cu_cp.yml` |
| Deployment | `srsran-cucp` | 執行 `srscucp -c /etc/config/cu_cp.yml` |
| Service | `srsran-cucp` | 暴露 E1AP / F1AP SCTP port |
| ServiceAccount | `srsran-cucp` | CU-CP pod 使用 |

預設 service ports：

| Port | Protocol | 用途 |
|------|----------|------|
| 38462 | SCTP | E1AP，CU-CP ↔ CU-UP |
| 38472 | SCTP | F1AP，CU-CP ↔ DU |

CU-CP 預設連到 free5GC AMF service：

```yaml
cu_cp:
  amf:
    addr: free5gc-v1-free5gc-amf-amf-n2
    port: 38412
    bind_addr: 0.0.0.0
```

#### CU-UP Chart

`charts/cuup` 部署 srsRAN CU-UP。

主要資源：

| 類型 | 名稱 | 說明 |
|------|------|------|
| ConfigMap | `srsran-cuup-config` | 產生 `/etc/config/cu_up.yml` |
| Deployment | `srsran-cuup` | 執行 `srscuup -c /etc/config/cu_up.yml` |
| Service | `srsran-cuup` | 暴露 F1-U UDP port |
| ServiceAccount | `srsran-cuup` | CU-UP pod 使用 |

CU-UP 使用 Multus 掛載 `n3` 與 `f1u` interface。預設沿用 free5GC UPF 的 N3 NAD：

```yaml
multus:
  n3interface:
    create: false
    nadName: "n3network-free5gc-v1-free5gc-upf"
    ngu:
      ipAddress: "10.100.50.234"
      gateway: "10.100.50.238"
    f1u:
      ipAddress: "10.100.50.235"
      gateway: "10.100.50.238"
```

對應 CU-UP config：

```yaml
cu_up:
  e1ap:
    cu_cp_addr: srsran-cucp
    bind_addr: 0.0.0.0
  ngu:
    socket:
      - bind_addr: 10.100.50.234
  f1u:
    socket:
      - bind_addr: 10.100.50.235
```

#### DU Chart

`charts/du` 部署 srsRAN DU，並以 ZMQ 模擬 RF device。

主要資源：

| 類型 | 名稱 | 說明 |
|------|------|------|
| ConfigMap | `srsran-du-config` | 產生 `/etc/config/du.yml` |
| Deployment | `srsran-du` | 執行 `srsdu -c /etc/config/du.yml` |
| Service | `srsran-du` | 暴露 ZMQ TCP port |
| NetworkAttachmentDefinition | `zmqnetwork-srsran-du` | DU ZMQ secondary network |
| ServiceAccount | `srsran-du` | DU pod 使用 |

DU 預設 interface：

| Interface | IP | 用途 |
|-----------|----|------|
| `f1u` | `10.100.50.236/29` | CU-UP ↔ DU user plane |
| `zmq` | `10.100.50.217/29` | DU ↔ UE ZMQ RF |

預設 20 MHz 設定：

```yaml
ru_sdr:
  device_driver: zmq
  device_args: tx_port=tcp://10.100.50.217:2000,rx_port=tcp://10.100.50.218:2001,base_srate=23.04e6
  srate: 23.04

cell_cfg:
  dl_arfcn: 368500
  band: 3
  channel_bandwidth_MHz: 20
  common_scs: 15
  plmn: "20893"
  tac: 1
```

`charts/du/values_10Mhz.yaml` 提供 10 MHz 變體：

| 項目 | 20 MHz 預設 | 10 MHz 變體 |
|------|-------------|-------------|
| `srate` | `23.04` | `11.52` |
| `channel_bandwidth_MHz` | `20` | `10` |
| `coreset0_index` | `12` | `6` |
| UE PRB | `106` | `52` |

### 6. Docker Images

`docker/` 目錄提供三個 image build context。

| Dockerfile | Image | 內容 |
|------------|-------|------|
| `Dockerfile.split-k8s` | `srsran-split:latest` | CU-CP/CU-UP/DU runtime image |
| `Dockerfile.srsue` | `srsran-ue:latest` | srsUE runtime image，含 iperf3/tcpdump |
| `Dockerfile.gnu-breaker` | `gnu-breaker:latest` | GNU Radio + Python ZMQ runtime |

`Dockerfile.split-k8s` 會從本 repo 的 local build artifacts 複製：

```text
build/apps/cu_cp/srscucp
build/apps/cu_up/srscuup
build/apps/du/srsdu
```

`Dockerfile.srsue` 會複製：

```text
build/srsue
```

> 注意：`docker/resources/entrypoint-*.sh` 使用 `/etc/config/gnb-config.yml`，這是後續 `srsran-operator` image 路徑使用的格式；目前 Helm chart 直接用 command/args 呼叫 `cu_cp.yml`、`cu_up.yml`、`du.yml`，未透過這些 entrypoint 啟動。

### 7. Log 與 PCAP

各 chart 會將 `/tmp/logs` 掛到 hostPath：

| Component | hostPath |
|-----------|----------|
| CU-CP | `/home/free5gc/srsran-helm/srsran-logs/cucp` |
| CU-UP | `/home/free5gc/srsran-helm/srsran-logs/cuup` |
| DU | `/home/free5gc/srsran-helm/srsran-logs/du` |
| UE | `/home/free5gc/srsran-helm/srsran-logs/ue` |
| UE2 | `/home/free5gc/srsran-helm/srsran-logs/ue2` |

CU-CP、CU-UP、DU values 預設啟用對應 PCAP；UE 預設啟用 NAS PCAP。

## 專案結構

```
srsran-helm/
├── charts/
│   ├── cucp/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   ├── cuup/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   ├── du/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values_10Mhz.yaml
│   │   └── templates/
│   ├── ue/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── values_10Mhz.yaml
│   │   ├── values_ue1.yaml
│   │   ├── values_ue2.yaml
│   │   └── templates/
│   └── gnu-breaker/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── files/multi_ue_scenario.py
│       └── templates/
├── docker/
│   ├── Dockerfile.split-k8s
│   ├── Dockerfile.srsue
│   ├── Dockerfile.gnu-breaker
│   └── resources/
│       ├── entrypoint-cucp.sh
│       ├── entrypoint-cuup.sh
│       ├── entrypoint-du.sh
│       └── entrypoint_srsue.sh
├── build/
│   ├── apps/cu_cp/srscucp
│   ├── apps/cu_up/srscuup
│   ├── apps/du/srsdu
│   └── srsue
├── multi_ue_scenario.grc
├── traffic_test.sh
└── Makefile
```

## 使用方式

### 建置 Images

```bash
# 建置 CU-CP/CU-UP/DU image
make build-image

# 建置 srsUE image
make build-ue-image

# 建置 GNU Radio breaker image
make build-gnu-breaker-image
```

推送到 Docker Hub：

```bash
DOCKERHUB_USER=qawl987 make push
DOCKERHUB_USER=qawl987 make push-gnu
```

或一次建置並推送：

```bash
make build-push
make build-push-gnu
```

### 主要流程：連接 Nephio gNB

先確保 Nephio / `srsran-operator` 已在 workload cluster 部署出 srsRAN gNB，且 DU ZMQ/F1U subnet 可由 UE chart 的 macvlan interface 連到。接著從本 repo 部署 GNU Radio bridge 和 UE：

```bash
# 1. 部署 GNU Radio ZMQ bridge
make gnu

# 2. 部署 UE1 / UE2
make ue1
make ue2

# 3. 透過 UE tunnel 做 iperf 測試
make iperf-ue1
make iperf-ue2
```

Makefile 會使用 `/home/free5gc/regional.kubeconfig` 連到 workload cluster，並把 UE 部署在 `srsran-ue` namespace、GNU Radio bridge 部署在 `srsran-gnu` namespace。

### 部署 UE

```bash
# UE1: eMBB slice / IMSI 208930000000001
make ue1

# UE2: URLLC slice / IMSI 208930000000002
make ue2
```

手動 Helm install：

```bash
KUBECONFIG=/home/free5gc/regional.kubeconfig \
helm upgrade --install ue1 -n srsran-ue \
  /home/free5gc/srsran-helm/charts/ue \
  -f /home/free5gc/srsran-helm/charts/ue/values_ue1.yaml

KUBECONFIG=/home/free5gc/regional.kubeconfig \
helm upgrade --install ue2 -n srsran-ue \
  /home/free5gc/srsran-helm/charts/ue \
  -f /home/free5gc/srsran-helm/charts/ue/values_ue2.yaml
```

`make ue` 仍保留單 UE chart 部署，但目前與 Nephio DU 連接測試主要使用 `ue1` / `ue2` values。

### 部署 GNU Radio Breaker

```bash
make gnu
```

`make gnu` 會先執行：

```bash
grcc multi_ue_scenario.grc -o ./charts/gnu-breaker/files/
```

然後部署 `charts/gnu-breaker` 到 `srsran-gnu` namespace。

### iperf 測試

Makefile 提供 UE1/UE2 iperf3 client 測試：

```bash
make iperf-ue1
make iperf-ue2
```

測試前，UPF/N6 側需要先有對應 server。可以搭配 `srsran-operator` 專案中的 UPF iperf setup，或手動在目標位址啟動：

```bash
iperf3 -s -B 10.0.1.254
iperf3 -s -B 10.0.1.253
```

`traffic_test.sh` 是另一個階梯式 UDP 壓測範例，會從 UE pod 透過 `uesimtun0` 對目標 server 逐步增加頻寬。

### Legacy：Helm 部署 gNB

```bash
# 早期完整 Helm 部署路徑，目前保留作為驗證/除錯用途
make free5gc
make gnb
```

等同於：

```bash
helm install srsran-cucp -n free5gc /home/free5gc/srsran-helm/charts/cucp
helm install srsran-cuup -n free5gc /home/free5gc/srsran-helm/charts/cuup
helm install srsran-du -n free5gc /home/free5gc/srsran-helm/charts/du
```

### 10 MHz 模式

DU 和 UE 都有 10 MHz values。現在 Nephio gNB 主線通常由 `srsran-operator` / Git repo 中的 `SrsRANConfig`、`SrsRANCellConfig` 控制 bandwidth；這裡的 10 MHz values 主要保留給 Helm legacy gNB 或單 UE chart 測試。

```bash
helm upgrade --install srsran-du -n free5gc \
  /home/free5gc/srsran-helm/charts/du \
  -f /home/free5gc/srsran-helm/charts/du/values_10Mhz.yaml

helm upgrade --install srsran-ue -n srsran-ue \
  /home/free5gc/srsran-helm/charts/ue \
  -f /home/free5gc/srsran-helm/charts/ue/values_10Mhz.yaml
```

### 驗證

```bash
# UE pods
KUBECONFIG=/home/free5gc/regional.kubeconfig \
kubectl get pods -n srsran-ue

# GNU Radio breaker
KUBECONFIG=/home/free5gc/regional.kubeconfig \
kubectl get pods -n srsran-gnu

# Nephio-deployed gNB pods
KUBECONFIG=/home/free5gc/regional.kubeconfig \
kubectl get pods -n srsran-gnb

# UE logs
KUBECONFIG=/home/free5gc/regional.kubeconfig \
kubectl logs -n srsran-ue deploy/srsran-ue1

KUBECONFIG=/home/free5gc/regional.kubeconfig \
kubectl logs -n srsran-ue deploy/srsran-ue2
```

### 清理

```bash
make uninstall-ue
make uninstall-ue1
make uninstall-ue2
make uninstall-gnu

# legacy gNB/free5GC 清理
make uninstall-gnb
make uninstall-free5gc
```

## 相依性

- Kubernetes cluster
- Helm
- Multus CNI 與 NetworkAttachmentDefinition CRD
- srsRAN split binaries 已存在於 `build/apps/...`
- srsUE binary 已存在於 `build/srsue`
- Docker，可用於 build/push images
- Nephio / `srsran-operator` 已部署 gNB 時，UE values 預期 DU ZMQ endpoint 位於 `172.6.0.0/24`
- free5GC / UPF / N6 iperf server 可達
- free5GC Helm chart 位於 `/home/free5gc/free5gc-helm/charts/free5gc`，僅 legacy gNB/free5GC target 需要
- GNU Radio Companion `grcc`，僅 `make gnu` 重新產生 flow graph 時需要
- KIND / microk8s 相關 import target 視環境選用

## 待整理項目

1. **UE 測試 values 與 Nephio 環境參數化**
   - 目前多個 IP、node name、namespace、NAD 名稱寫死在 values 或 Makefile 中
   - 後續可整理成環境專用 values 檔，例如 `values-nephio-regional-ue1.yaml`

2. **Helm chart 與 operator image entrypoint 對齊**
   - Docker entrypoint 使用 `/etc/config/gnb-config.yml`
   - Helm chart 目前直接呼叫 binary 並使用 `cu_cp.yml`、`cu_up.yml`、`du.yml`

3. **GNU Radio bridge 動態化**
   - `multi_ue_scenario.py` 目前固定 two-UE endpoint
   - 後續可由 values 產生 endpoint 或改用 ConfigMap template

4. **log artifacts 管理**
   - `srsran-logs/` 是 hostPath runtime artifact，不適合納入版本控制
   - 建議以 `.gitignore` 或外部 artifact collection 管理

5. **Legacy gNB chart 標註**
   - CU-CP/CU-UP/DU Helm chart 已不是目前主線
   - 後續可移到 `legacy/` 或在 chart README 中明確標註為歷史部署驗證用途

## 授權

請依照上游 srsRAN、GNU Radio 與本專案實際授權條款使用。
