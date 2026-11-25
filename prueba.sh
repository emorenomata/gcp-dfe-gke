# 1. Crear el clúster regional privado con un pool bootstrap mínimo (e2-micro)
#    y acceso por DNS endpoint para evitar bloqueos de red/IP autorizadas.
gcloud container clusters create "${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --release-channel="regular" \
  --machine-type="e2-micro" \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=3 \
  --autoscaling-profile="optimize-utilization" \
  --location-policy="ANY" \
  --enable-private-nodes \
  --enable-ip-alias \
  --enable-dns-access \
  --enable-default-compute-class
  

# 2. Aplicar el ComputeClass 'default' con cascada de familias (n4 -> c3 -> n2 -> e2)
kubectl apply -f manifests/01-computeclass-default.yaml

