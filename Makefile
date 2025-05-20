KIND_CLUSTER_NAME     := demo
TRINO_HELM_VERSION := 1.39.0
DOCKER_IMAGE_NAME := "hive/metastore_s3_pg:0.0.1"


.PHONY: kind-up
kind-up:
	kind create cluster --name $(KIND_CLUSTER_NAME)

.PHONY: kind-down
kind-down: kind-use-context
	kind delete cluster --name $(KIND_CLUSTER_NAME)

.PHONY: kind-use-context
kind-use-context:
	@kubectl config use-context kind-$(KIND_CLUSTER_NAME)

.PHONY: build-docker
build-docker:
	docker build -t $(DOCKER_IMAGE_NAME) -f $(CURDIR)/docker/Dockerfile $(CURDIR)/docker

.PHONY: kind-upload-image
kind-upload-image:
	kind load docker-image $(DOCKER_IMAGE_NAME) --name $(KIND_CLUSTER_NAME)

.PHONY: metastore-up
metastore-up: build-docker kind-use-context kind-upload-image
	kubectl create namespace metastore --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f $(CURDIR)/k8s/metastore -n metastore
	kubectl wait --for=condition=available --timeout=300s deployment/hive-metastore -n metastore

.PHONY: minio-up
minio-up:
	kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f $(CURDIR)/k8s/minio -n minio
	kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset/minio -n minio

.PHONY: minio-pf
minio-pf:
	kubectl port-forward svc/minio-service 9001:9001 -n minio

.PHONY: trino-helm-up
trino-helm-up:
	helm repo list | grep -q 'trino' || helm repo add trino https://trinodb.github.io/charts
	helm repo update

.PHONY: trino-up
trino-up:
	kubectl create namespace trino --dry-run=client -o yaml | kubectl apply -f -
	helm install trino trino/trino --version $(TRINO_HELM_VERSION) -f $(CURDIR)/helm/trino-values.yaml -n trino
	kubectl wait --for=condition=available --timeout=500s deployment/trino-coordinator -n trino

.PHONY: trino-update
trino-update:
	helm upgrade trino trino/trino --version $(TRINO_HELM_VERSION) -f $(CURDIR)/helm/trino-values.yaml -n trino
	kubectl wait --for=condition=available --timeout=300s deployment/trino-coordinator -n trino

.PHONY: trino-down
trino-down: kind-use-context
	helm delete trino -n trino
	kubectl delete namespace trino

# default username: admin
# no password
.PHONY: trino-pf
trino-pf: kind-use-context
	kubectl --namespace trino port-forward svc/trino 8080:8080

.PHONY: trino-coordinator-client
trino-coordinator-client: kind-use-context
	POD_NAME=$$(kubectl get pods -n trino -l "app.kubernetes.io/name=trino,app.kubernetes.io/instance=trino,app.kubernetes.io/component=coordinator" -o jsonpath='{.items[0].metadata.name}'); \
	if [ -z "$$POD_NAME" ]; then \
		echo "Error: Trino coordinator pod not found."; \
		exit 1; \
	fi; \
	kubectl exec -it "$$POD_NAME" -n trino -- bash -c "trino"

.PHONY: all
all: kind-up minio-up metastore-up trino-helm-up trino-up

# For scaling trino a metrics server is required
.PHONY: metrics-server-up
metrics-server-up:
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl patch deployment metrics-server -n kube-system --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
	kubectl wait --for=condition=available --timeout=300s deployment/metrics-server -n kube-system