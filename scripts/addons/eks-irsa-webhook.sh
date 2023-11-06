#!/bin/bash

set -ex

IMAGE=${1}
NAMESPACE=${2}
REPLICAS=${3:-1}

required_args=(
    IMAGE
    NAMESPACE
)

for arg in "${required_args[@]}"; do
  if [ -z "${!arg}" ]; then
    echo "${arg} is required"
    exit 1
  fi
done

BASE_DIR=/home/ubuntu/amazon-eks-pod-identity-webhook
git clone https://github.com/aws/amazon-eks-pod-identity-webhook.git ${BASE_DIR}

cat <<EOF | tee ${BASE_DIR}/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: pod-identity-webhook
  template:
    metadata:
      labels:
        app: pod-identity-webhook
    spec:
      serviceAccountName: pod-identity-webhook
      containers:
      - name: pod-identity-webhook
        image: ${IMAGE}
        imagePullPolicy: Always
        command:
        - /webhook
        - --in-cluster=false
        - --namespace=${NAMESPACE}
        - --service-name=pod-identity-webhook
        - --annotation-prefix=eks.amazonaws.com
        - --token-audience=sts.amazonaws.com
        - --logtostderr
        volumeMounts:
        - name: cert
          mountPath: "/etc/webhook/certs"
          readOnly: true
      volumes:
      - name: cert
        secret:
          secretName: pod-identity-webhook-cert
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
spec:
  secretName: pod-identity-webhook-cert
  commonName: "pod-identity-webhook.${NAMESPACE}.svc"
  dnsNames:
  - "pod-identity-webhook"
  - "pod-identity-webhook.${NAMESPACE}"
  - "pod-identity-webhook.${NAMESPACE}.svc"
  - "pod-identity-webhook.${NAMESPACE}.svc.cluster.local"
  isCA: true
  duration: 2160h # 90d
  renewBefore: 360h # 15d
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
EOF

cat <<EOF | tee ${BASE_DIR}/service.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
rules:
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - create
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - get
  - update
  - patch
  resourceNames:
  - "pod-identity-webhook"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-identity-webhook
subjects:
- kind: ServiceAccount
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-identity-webhook
rules:
- apiGroups:
  - ""
  resources:
  - serviceaccounts
  verbs:
  - get
  - watch
  - list
- apiGroups:
  - certificates.k8s.io
  resources:
  - certificatesigningrequests
  verbs:
  - create
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pod-identity-webhook
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pod-identity-webhook
subjects:
- kind: ServiceAccount
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
EOF

cat <<EOF | tee ${BASE_DIR}/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
  annotations:
    prometheus.io/port: "443"
    prometheus.io/scheme: "https"
    prometheus.io/scrape: "true"
spec:
  ports:
  - port: 443
    targetPort: 443
  selector:
    app: pod-identity-webhook
EOF

cat <<EOF | tee ${BASE_DIR}/mutatingwebhook.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: pod-identity-webhook
  namespace: ${NAMESPACE}
  annotations:
    cert-manager.io/inject-ca-from: default/pod-identity-webhook
webhooks:
- name: pod-identity-webhook.amazonaws.com
  failurePolicy: Ignore
  clientConfig:
    service:
      name: pod-identity-webhook
      namespace: ${NAMESPACE}
      path: "/mutate"
  rules:
  - operations: [ "CREATE" ]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  sideEffects: None
  admissionReviewVersions: ["v1beta1"]
EOF

kubectl apply -f ${BASE_DIR}/deployment.yaml